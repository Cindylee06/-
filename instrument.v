// Tang Nano 20K + Music Carrier Rev A. All state uses the 27 MHz clock.
module instrument #(
    parameter TOUCH_ACTIVE_HIGH = 1,
    parameter BAUD = 9600
)(
    input clk27, input [3:0] touch_in,
    input uart_rx, output uart_tx,
    inout i2c_scl, i2c_sda,
    output i2s_bck, i2s_lrck, i2s_dout, dac_unmute,
    output led_data, led_spare,
    output amp_enable, lcd_bl_enable, adc_cs_n, adc_sck, adc_mosi
);
    // FF power-up value is implemented in the bitstream. Hold synchronous
    // reset while the clock settles, then saturate the counter.
    reg [7:0] startup = 0;
    wire reset = !(&startup);
    always @(posedge clk27) if (reset) startup <= startup + 1'b1;

    assign amp_enable = 1'b0;
    assign lcd_bl_enable = 1'b0;
    assign adc_cs_n = 1'b1;
    assign adc_sck = 1'b0;
    assign adc_mosi = 1'b0;
    assign led_spare = 1'b0;

    wire [3:0] touch, remote_notes, level;
    wire [3:0] notes = touch | remote_notes;
    wire sensor_online;
    wire [7:0] sensor_id;
    wire [9:0] proximity;
    wire [3:0] sensor_diag;
    reg [3:0] volume;
    reg [1:0] timbre;
    touch_filter keys (.clk(clk27), .reset(reset),
        .raw(TOUCH_ACTIVE_HIGH ? touch_in : ~touch_in), .pressed(touch));
    bluetooth #(.BAUD(BAUD)) ble (.clk(clk27), .reset(reset), .rx(uart_rx),
        .touch(touch), .tx(uart_tx), .remote_notes(remote_notes),
        .online(sensor_online), .chip_id(sensor_id), .proximity(proximity),
        .volume(volume), .timbre(timbre), .diag_code(sensor_diag));

    wire louder, softer, next_timbre;
    sensor prox (.clk(clk27), .reset(reset), .scl(i2c_scl), .sda(i2c_sda),
        .volume_up(louder), .volume_down(softer), .timbre_next(next_timbre),
        .online(sensor_online), .chip_id(sensor_id), .proximity(proximity),
        .diag_code(sensor_diag));
    always @(posedge clk27) begin
        if (reset) begin
            volume <= 8;
            timbre <= 0;
        end else begin
            if (louder && volume != 15) volume <= volume + 1'b1;
            if (softer && volume != 0) volume <= volume - 1'b1;
            if (next_timbre) timbre <= timbre == 2 ? 0 : timbre + 1'b1;
        end
    end
    audio synth (.clk(clk27), .reset(reset), .notes(notes), .timbre(timbre),
        .volume(volume), .level(level), .bck(i2s_bck), .lrck(i2s_lrck),
        .dout(i2s_dout), .unmute(dac_unmute));
    strip lights (.clk(clk27), .reset(reset), .notes(notes), .level(level), .data(led_data));
endmodule

module touch_filter #(parameter COUNT_BITS = 14)(
    input clk, reset, input [3:0] raw, output reg [3:0] pressed
);
    reg [3:0] sync1, sync2;
    always @(posedge clk) begin
        if (reset) begin
            sync1 <= 4'hf;
            sync2 <= 4'hf;
        end else begin
            sync1 <= raw;
            sync2 <= sync1;
        end
    end
    // Rev A pulls unused inputs high. Arm each key only after a stable
    // release, so an absent active-high module doesn't play a stuck note.
    genvar i;
    generate for (i=0; i<4; i=i+1) begin : gate
        reg armed;
        reg [COUNT_BITS-1:0] count;
        always @(posedge clk) begin
            if (reset) begin
                armed <= 0;
                pressed[i] <= 0;
                count <= 0;
            end else if ((!armed && !sync2[i]) ||
                         (armed && (sync2[i] != pressed[i]))) begin
                if (&count) begin
                    armed <= 1;
                    pressed[i] <= sync2[i];
                end
                count <= count + 1'b1;
            end else count <= 0;
        end
    end endgenerate
endmodule
