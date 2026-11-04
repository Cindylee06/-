// APDS-9930 (AV02-3190EN) and APDS-9960 compatible parts (AV02-4191EN).
// Both use seven-bit address 0x39; their proximity register maps differ.
module sensor #(
    parameter QUARTER_CYCLES = 68,        // 27 MHz / (4 * 68) = 99.26 kHz
    parameter POLL_CYCLES = 540000,       // wait 20 ms between samples
    parameter RETRY_CYCLES = 2700000,     // retry offline device after 100 ms
    parameter ENTER_LEVEL = 180,          // raw proximity counts, not distance
    parameter LEAVE_LEVEL = 120,
    parameter LOUDER_LEVEL = 450,
    parameter HOLD_SAMPLES = 25,          // about 0.5 s
    parameter REPEAT_SAMPLES = 8
)(
    input clk, reset,
    inout scl, sda,
    output reg volume_up, volume_down, timbre_next,
    output reg online,
    output reg [9:0] proximity, // Last successful PDATA read; retained offline
    output reg [7:0] chip_id,   // Last successful ID read, including unknown IDs
    output reg [3:0] diag_code  // Held through retries until a new diagnostic result
);
    localparam ID=0, DISABLE=1, ATIME=2, PTIME=3, WTIME=4, PULSE=5,
               CONTROL=6, NOBOOST=7, ENABLE=8, STATUS=9, PROX=10;
    reg [3:0] step;
    reg family9960;
    reg [7:0] command_byte, wr_data;
    reg [1:0] rd_len;
    always @* begin
        command_byte = 8'h80;
        wr_data = 0;
        rd_len = 0;
        case (step)
            ID:      begin command_byte = 8'h92; rd_len = 1; end
            DISABLE: begin command_byte = 8'h80; wr_data = 0; end
            ATIME:   begin command_byte = 8'h81; wr_data = 8'hff; end
            PTIME:   begin command_byte = 8'h82; wr_data = 8'hff; end
            WTIME:   begin command_byte = 8'h83; wr_data = 8'hff; end
            PULSE:   begin command_byte = 8'h8e; wr_data = family9960 ? 8'h47 : 8'h08; end
            CONTROL: begin command_byte = 8'h8f; wr_data = family9960 ? 8'h88 : 8'ha8; end
            NOBOOST: begin command_byte = 8'h90; wr_data = 8'h01; end // 9960 only: no current boost
            ENABLE:  begin command_byte = 8'h80; wr_data = family9960 ? 8'h0d : 8'h0f; end
            STATUS:  begin command_byte = 8'h93; rd_len = 1; end
            PROX: begin
                command_byte = family9960 ? 8'h9c : 8'hb8;
                rd_len = family9960 ? 1 : 2;
            end
        endcase
    end

    reg request;
    wire done, failed;
    wire [3:0] bus_error;
    wire [15:0] rd_data;
    // These are the 9960 IDs handled by ESPHome's apds9960 component.
    wire id9960 = rd_data[7:0]==8'hab || rd_data[7:0]==8'h9c ||
                  rd_data[7:0]==8'ha8 || rd_data[7:0]==8'h9e;
    wire [9:0] sample_value = family9960 ? {rd_data[7:0],2'b00} : rd_data[9:0];
    reg [1:0] invalid_polls;
    apds_reg_io #(.QUARTER_CYCLES(QUARTER_CYCLES)) bus (
        .clk(clk), .reset(reset), .request(request), .command_byte(command_byte),
        .wr_data(wr_data), .rd_len(rd_len), .scl(scl), .sda(sda),
        .done(done), .failed(failed), .bus_error(bus_error), .rd_data(rd_data)
    );

    reg [$clog2((RETRY_CYCLES>POLL_CYCLES ? RETRY_CYCLES:POLL_CYCLES)+1)-1:0] delay_count;
    reg waiting, armed, near_hand;
    reg [$clog2(HOLD_SAMPLES+1)-1:0] dwell;
    reg [$clog2(REPEAT_SAMPLES+1)-1:0] repeat_count;
    always @(posedge clk) begin
        request <= 0;
        volume_up <= 0;
        volume_down <= 0;
        timbre_next <= 0;
        if (reset) begin
            step <= ID;
            family9960 <= 0;
            invalid_polls <= 0;
            delay_count <= RETRY_CYCLES;
            waiting <= 0;
            online <= 0;
            proximity <= 0;
            chip_id <= 0;
            diag_code <= 0;
            armed <= 0;
            near_hand <= 0;
            dwell <= 0;
            repeat_count <= 0;
        end else if (delay_count != 0) begin
            delay_count <= delay_count - 1'b1;
        end else if (!waiting) begin
            request <= 1;
            waiting <= 1;
        end else if (done) begin
            waiting <= 0;
            if (step == ID && !failed) begin
                chip_id <= rd_data[7:0];
                family9960 <= id9960;
            end
            if (failed || (step==ID && rd_data[7:0]!=8'h39 && !id9960) ||
                          (step==STATUS && !rd_data[1] && (!family9960 || &invalid_polls))) begin
                // A rebooted sensor has PVALID=0. Reconfigure, and require
                // a far sample before accepting the next gesture.
                step <= ID;
                if (failed) diag_code <= bus_error; // 2..5 from bus
                else diag_code <= step == ID ? 4'd6 : 4'd7;
                delay_count <= RETRY_CYCLES;
                online <= 0;
                invalid_polls <= 0;
                armed <= 0;
                near_hand <= 0;
                dwell <= 0;
                repeat_count <= 0;
            end else if (step == STATUS && !rd_data[1]) begin
                // Reading 9960 PDATA clears PVALID. Poll for the next cycle;
                // if four polls fail, probe again in case it lost power.
                diag_code <= 4'd7;
                invalid_polls <= invalid_polls + 1'b1;
                delay_count <= POLL_CYCLES;
            end else if (step != PROX) begin
                step <= step + 1'b1;
                if (step == DISABLE && family9960) step <= WTIME; // no PTIME on 9960
                if (step == CONTROL && !family9960) step <= ENABLE;
                if (step == ENABLE)
                    delay_count <= POLL_CYCLES;
            end else begin
                online <= 1;
                proximity <= sample_value;
                invalid_polls <= 0;
                diag_code <= 4'd1;
                step <= STATUS;
                delay_count <= POLL_CYCLES;
                if (sample_value <= LEAVE_LEVEL) begin
                    if (near_hand && dwell >= 2 && dwell < HOLD_SAMPLES)
                        timbre_next <= 1;
                    armed <= 1;
                    near_hand <= 0;
                    dwell <= 0;
                    repeat_count <= 0;
                end else if (!near_hand) begin
                    if (armed && sample_value >= ENTER_LEVEL) begin
                        near_hand <= 1;
                        dwell <= 1;
                    end
                end else if (dwell < HOLD_SAMPLES-1) begin
                    dwell <= dwell + 1'b1;
                end else if (repeat_count == 0) begin
                    dwell <= HOLD_SAMPLES;
                    repeat_count <= REPEAT_SAMPLES-1;
                    volume_up <= sample_value >= LOUDER_LEVEL;
                    volume_down <= sample_value < LOUDER_LEVEL;
                end else begin
                    repeat_count <= repeat_count - 1'b1;
                end
            end
        end
    end
endmodule

// Fixed-address single-master transaction: write register, or write pointer
// then repeated START and read one/two bytes. All pin changes use clk only.
module apds_reg_io #(parameter QUARTER_CYCLES=68)(
    input clk, reset, request,
    input [7:0] command_byte, wr_data,
    input [1:0] rd_len,
    inout scl, sda,
    output reg done, output failed, output reg [3:0] bus_error,
    output reg [15:0] rd_data
);
    localparam IDLE=0, BUS_FREE=1, START_LOW=2, BIT_SETUP=3, BIT_HIGH=4,
               SAMPLE=5, BIT_LOW=6, RESTART_SETUP=7, RESTART_HIGH=8,
               RESTART_START=9, STOP_SETUP=10, STOP_HIGH=11, STOP_END=12,
               CLEAR_LOW=13, CLEAR_HIGH=14, CLEAR_SAMPLE=15;
    reg [3:0] state;
    reg scl_low, sda_low;
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;
    reg [1:0] scli, sdai;
    always @(posedge clk) begin
        scli <= {scli[0],scl};
        sdai <= {sdai[0],sda};
    end

    reg [$clog2(QUARTER_CYCLES+1)-1:0] divider;
    reg [9:0] watchdog;
    reg [3:0] clear_clocks;
    reg [3:0] bit_no; // 0..7 data, 8 ACK
    reg [2:0] slot;    // device(W), register, data/device(R), read low, read high
    reg [7:0] tx_byte, rx_shift;
    reg nack;
    assign failed = |bus_error;
    always @(posedge clk) begin
        done <= 0;
        if (reset) begin
            state <= IDLE;
            scl_low <= 0;
            sda_low <= 0;
            bus_error <= 0;
            divider <= 0;
            watchdog <= 0;
            rd_data <= 0;
            bit_no <= 0;
            slot <= 0;
            tx_byte <= 0;
            rx_shift <= 0;
            nack <= 0;
        end else if (state == IDLE) begin
            if (request) begin
                divider <= QUARTER_CYCLES-1;
                watchdog <= 0;
                bus_error <= 0;
                slot <= 0;
                bit_no <= 0;
                tx_byte <= 8'h72; // addr 0x39, write
                rd_data <= 0;
                state <= BUS_FREE;
            end
        end else if (divider != 0) begin
            divider <= divider - 1'b1;
        end else begin
            divider <= QUARTER_CYCLES-1;
            watchdog <= watchdog + 1'b1;
            if (&watchdog) begin // stalled bus; release all pins and retry later
                scl_low <= 0;
                sda_low <= 0;
                bus_error <= 4'd2; // transaction timeout
                done <= 1;
                state <= IDLE;
            end else case (state)
                BUS_FREE: if (scli[1]) begin
                    if (sdai[1]) begin
                        sda_low <= 1;
                        state <= START_LOW;
                    end else begin
                        // If the FPGA restarted during a read, the slave can
                        // still own SDA. Clock out its byte, STOP, then retry.
                        scl_low <= 1;
                        clear_clocks <= 0;
                        state <= CLEAR_LOW;
                    end
                end
                CLEAR_LOW: state <= CLEAR_HIGH;
                CLEAR_HIGH: begin scl_low <= 0; state <= CLEAR_SAMPLE; end
                CLEAR_SAMPLE: if (scli[1]) begin
                    scl_low <= 1;
                    if (clear_clocks == 8) begin
                        bus_error <= 4'd3; // SDA was busy; bus clear and retry
                        state <= STOP_SETUP;
                    end else begin
                        clear_clocks <= clear_clocks + 1'b1;
                        state <= CLEAR_LOW;
                    end
                end
                START_LOW: begin
                    scl_low <= 1;
                    state <= BIT_SETUP;
                end
                BIT_SETUP: begin
                    if (slot < 3) sda_low <= (bit_no < 8) && !tx_byte[7];
                    else sda_low <= (bit_no == 8) && (slot == 3) && (rd_len == 2);
                    state <= BIT_HIGH;
                end
                BIT_HIGH: begin
                    scl_low <= 0;
                    state <= SAMPLE;
                end
                SAMPLE: if (scli[1]) begin
                    if (bit_no < 8 && slot >= 3)
                        rx_shift <= {rx_shift[6:0],sdai[1]};
                    if (bit_no == 8 && slot < 3)
                        nack <= sdai[1];
                    state <= BIT_LOW;
                end
                BIT_LOW: begin
                    scl_low <= 1;
                    if (bit_no < 8) begin
                        bit_no <= bit_no + 1'b1;
                        tx_byte <= {tx_byte[6:0],1'b0};
                        state <= BIT_SETUP;
                    end else begin
                        bit_no <= 0;
                        slot <= slot + 1'b1;
                        if (slot < 3 && nack) begin
                            bus_error <= slot == 0 ? 4'd4 : 4'd5; // address vs later NACK
                            state <= STOP_SETUP;
                        end else case (slot)
                            0: begin tx_byte <= command_byte; state <= BIT_SETUP; end
                            1: if (rd_len == 0) begin
                                tx_byte <= wr_data;
                                state <= BIT_SETUP;
                            end else begin
                                tx_byte <= 8'h73;
                                state <= RESTART_SETUP;
                            end
                            2: state <= (rd_len == 0) ? STOP_SETUP : BIT_SETUP;
                            3: begin
                                rd_data[7:0] <= rx_shift;
                                state <= (rd_len == 2) ? BIT_SETUP : STOP_SETUP;
                            end
                            default: begin rd_data[15:8] <= rx_shift; state <= STOP_SETUP; end
                        endcase
                    end
                end
                RESTART_SETUP: begin sda_low <= 0; state <= RESTART_HIGH; end
                RESTART_HIGH:  begin scl_low <= 0; state <= RESTART_START; end
                RESTART_START: if (scli[1]) begin sda_low <= 1; state <= START_LOW; end
                STOP_SETUP: begin sda_low <= 1; state <= STOP_HIGH; end
                STOP_HIGH:  begin scl_low <= 0; state <= STOP_END; end
                STOP_END: if (scli[1]) begin
                    sda_low <= 0;
                    done <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
