// Eight WS2812(B) pixels. Data is GRB, MSB first. At 27 MHz each
// bit is 34 cycles (1.259 us), high for 9 or 18 cycles (333 / 667 ns).
module strip #(parameter FRAME_CYCLES = 270000)(
    input clk, reset, input [3:0] notes, level, output reg data
);
    reg [$clog2(FRAME_CYCLES)-1:0] frame_timer;
    reg [3:0] window_peak, display_peak;
    reg [3:0] held_notes;
    reg [2:0] pixel;
    reg [4:0] bit_index;
    reg [5:0] tick;
    reg sending;
    reg [23:0] color;
    always @* begin
        case (pixel)
            0: color = held_notes[0] ? 24'h032000 : 0; // red
            1: color = held_notes[1] ? 24'h180006 : 0; // green
            2: color = held_notes[2] ? 24'h02031f : 0; // blue
            3: color = held_notes[3] ? 24'h0e2000 : 0; // amber
            4: color = display_peak >= 1 ? 24'h100000 : 0;
            5: color = display_peak >= 2 ? 24'h150500 : 0;
            6: color = display_peak >= 4 ? 24'h0c1800 : 0;
            7: color = display_peak >= 7 ? 24'h011d00 : 0;
        endcase
    end
    always @(posedge clk) begin
        if (reset) begin
            frame_timer <= 0;
            window_peak <= 0;
            display_peak <= 0;
            held_notes <= 0;
            pixel <= 0;
            bit_index <= 23;
            tick <= 0;
            sending <= 0;
            data <= 0;
        end else begin
            if (level > window_peak) window_peak <= level;
            if (frame_timer == FRAME_CYCLES-1) begin
                frame_timer <= 0;
                held_notes <= notes;
                if (window_peak >= display_peak) display_peak <= window_peak;
                else display_peak <= display_peak - 1'b1;
                window_peak <= level;
                pixel <= 0;
                bit_index <= 23;
                tick <= 0;
                sending <= 1;
            end else frame_timer <= frame_timer + 1'b1;

            if (sending) begin
                data <= tick < (color[bit_index] ? 18 : 9);
                if (tick == 33) begin
                    tick <= 0;
                    if (bit_index == 0) begin
                        bit_index <= 23;
                        pixel <= pixel + 1'b1;
                        if (pixel == 7) sending <= 0;
                    end else bit_index <= bit_index - 1'b1;
                end else tick <= tick + 1'b1;
            end else data <= 0;
        end
    end
endmodule
