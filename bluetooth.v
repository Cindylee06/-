// HC-08 transparent UART bridge, idle high, 8 data bits, no parity, one stop.
// Phone writes ASCII bytes: 1..4 = key down, a..d = key up, 0 = release
// all remote notes, ? = read touch keys, ! = read diagnostics. Unknown bytes
// (including CR/LF)
// are ignored. On connect send "0?" to clear notes left by a lost link.
// FPGA sends K + one uppercase hex digit + LF at startup, on local changes
// and on query. Bit 0 = touch 1. Each frame is one snapshot; updates that
// arrive while transmitting are coalesced into the newest state.
// ! returns G + online(1 hex) + chip ID(2) + proximity(3) + volume(1) +
// timbre(1) + diagnostic code(1) + LF. Both frame types share TX fairly.
module bluetooth #(
    parameter integer CLK_HZ = 27000000,
    parameter integer BAUD = 9600
) (
    input clk, reset, rx,
    input [3:0] touch,
    input online,
    input [7:0] chip_id,
    input [9:0] proximity,
    input [3:0] volume,
    input [1:0] timbre,
    input [3:0] diag_code,
    output tx,
    output reg [3:0] remote_notes
);
    localparam integer BIT_TICKS = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer COUNT_BITS = $clog2(BIT_TICKS);

    reg rx_meta, rx_sync;
    always @(posedge clk) begin
        if (reset) begin
            rx_meta <= 1;
            rx_sync <= 1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    localparam RX_IDLE = 3'd0, RX_START = 3'd1, RX_DATA = 3'd2,
               RX_STOP = 3'd3, RX_WAIT_MARK = 3'd4;
    reg [2:0] rx_state, bit_index;
    reg [COUNT_BITS-1:0] rx_ticks;
    reg [7:0] rx_byte;
    wire byte_valid = rx_state == RX_STOP && rx_ticks == 0 && rx_sync;

    always @(posedge clk) begin
        if (reset) begin
            rx_state <= RX_IDLE;
            rx_ticks <= 0;
            bit_index <= 0;
            rx_byte <= 0;
        end else case (rx_state)
            RX_IDLE: if (!rx_sync) begin
                rx_state <= RX_START;
                rx_ticks <= BIT_TICKS/2 - 1;
            end
            RX_WAIT_MARK: if (rx_sync) rx_state <= RX_IDLE;
            default: if (rx_ticks != 0) rx_ticks <= rx_ticks - 1'b1;
            else begin
                rx_ticks <= BIT_TICKS - 1;
                case (rx_state)
                    RX_START: begin
                        rx_state <= rx_sync ? RX_IDLE : RX_DATA;
                        bit_index <= 0;
                    end
                    RX_DATA: begin
                        rx_byte[bit_index] <= rx_sync;
                        bit_index <= bit_index + 1'b1;
                        if (bit_index == 7) rx_state <= RX_STOP;
                    end
                    RX_STOP: rx_state <= rx_sync ? RX_IDLE : RX_WAIT_MARK;
                    default: rx_state <= RX_IDLE;
                endcase
            end
        endcase
    end

    always @(posedge clk) begin
        if (reset) remote_notes <= 0;
        else if (byte_valid) case (rx_byte)
            "1": remote_notes[0] <= 1;
            "2": remote_notes[1] <= 1;
            "3": remote_notes[2] <= 1;
            "4": remote_notes[3] <= 1;
            "a": remote_notes[0] <= 0;
            "b": remote_notes[1] <= 0;
            "c": remote_notes[2] <= 0;
            "d": remote_notes[3] <= 0;
            "0": remote_notes <= 0;
            default: ;
        endcase
    end

    reg [9:0] tx_shift;
    reg [3:0] bits_left;
    reg [COUNT_BITS-1:0] tx_ticks;
    reg [35:0] hex_digits; // remaining snapshot nibbles, most significant first
    reg [3:0] digits_left;
    reg lf_pending;
    reg [3:0] snapshot;
    reg report_pending, diagnostic_pending, last_was_diagnostic;
    wire touch_pending = report_pending || touch != snapshot;
    wire choose_diagnostic = diagnostic_pending &&
                             (!touch_pending || !last_was_diagnostic);
    wire [3:0] nibble = hex_digits[35:32];
    wire [7:0] hex_char = nibble < 10 ? 8'h30 + nibble : 8'h37 + nibble;
    assign tx = tx_shift[0];

    always @(posedge clk) begin
        if (reset) begin
            tx_shift <= 10'h3ff;
            bits_left <= 0;
            tx_ticks <= 0;
            hex_digits <= 0;
            digits_left <= 0;
            lf_pending <= 0;
            snapshot <= 0;
            report_pending <= 1;
            diagnostic_pending <= 0;
            last_was_diagnostic <= 0;
        end else begin
            if (bits_left != 0) begin
                if (tx_ticks != 0) tx_ticks <= tx_ticks - 1'b1;
                else begin
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    bits_left <= bits_left - 1'b1;
                    tx_ticks <= BIT_TICKS - 1;
                end
            end else if (lf_pending || touch_pending || diagnostic_pending) begin
                bits_left <= 10;
                tx_ticks <= BIT_TICKS - 1;
                if (digits_left != 0) begin
                    tx_shift <= {1'b1, hex_char, 1'b0};
                    hex_digits <= {hex_digits[31:0],4'b0};
                    digits_left <= digits_left - 1'b1;
                end else if (lf_pending) begin
                    tx_shift <= {1'b1, 8'h0A, 1'b0};
                    lf_pending <= 0;
                end else begin
                    lf_pending <= 1;
                    last_was_diagnostic <= choose_diagnostic;
                    if (choose_diagnostic) begin
                        tx_shift <= {1'b1, 8'h47, 1'b0}; // 'G'
                        hex_digits <= {3'b0, online, chip_id, 2'b0, proximity,
                                       volume, 2'b0, timbre, diag_code};
                        digits_left <= 9;
                        diagnostic_pending <= 0;
                    end else begin
                        tx_shift <= {1'b1, 8'h4B, 1'b0}; // 'K'
                        hex_digits <= {touch,32'b0};
                        digits_left <= 1;
                        snapshot <= touch;
                        report_pending <= 0;
                    end
                end
            end
            if (byte_valid && rx_byte == "?") report_pending <= 1;
            if (byte_valid && rx_byte == "!") diagnostic_pending <= 1;
        end
    end
endmodule
