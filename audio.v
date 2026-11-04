// 27 MHz logic throughout. The DAC clock pins are registered data outputs.
module audio(
    input clk, input reset, input [3:0] notes,
    input [1:0] timbre, input [3:0] volume,
    output reg bck, output reg lrck, output reg dout, output reg unmute,
    output [3:0] level
);
    // TI PCM5102A: three-wire PLL, SCK tied low, 64 BCK/frame.
    // 27 MHz / 9 / 64 = 46875 Hz (-2.344% of nominal 48 kHz).
    reg [3:0] divider;
    reg [5:0] bit_slot;
    wire frame_start = divider == 8 && bit_slot == 0;

    wire signed [17:0] c4, d4, e4, g4;
    // Phase increments round(2^24 * note_Hz / 46875).
    audio_voice #(24'd93639)  voice_c(clk, reset, frame_start, notes[0], timbre, c4);
    audio_voice #(24'd105107) voice_d(clk, reset, frame_start, notes[1], timbre, d4);
    audio_voice #(24'd117978) voice_e(clk, reset, frame_start, notes[2], timbre, e4);
    audio_voice #(24'd140301) voice_g(clk, reset, frame_start, notes[3], timbre, g4);

    // Pipeline the mixer, leaving headroom even at all four peak amplitudes.
    reg signed [18:0] pair_cd, pair_eg;
    reg signed [19:0] chord;
    reg signed [22:0] gained;
    always @(posedge clk) begin
        if (reset) begin
            pair_cd <= 0;
            pair_eg <= 0;
            chord <= 0;
            gained <= 0;
        end else begin
            pair_cd <= c4 + d4;
            pair_eg <= e4 + g4;
            chord <= pair_cd + pair_eg;
            gained <= chord * $signed({1'b0,volume});
        end
    end

    reg [31:0] frame_word, shift_word;
    // Level follows the transmitted frame (0..15), including startup mute.
    wire [31:0] magnitude = frame_word[31] ? (~frame_word + 1'b1) : frame_word;
    assign level = magnitude[30:27];

    reg [10:0] warm_frames;
    always @(posedge clk) begin
        if (reset) begin
            divider <= 0;
            bit_slot <= 0;
            bck <= 0;
            lrck <= 1;
            dout <= 0;
            shift_word <= 0;
            frame_word <= 0;
            warm_frames <= 0;
            unmute <= 0;
        end else begin
            divider <= divider + 1'b1;
            if (divider == 4) bck <= 1;
            if (divider == 8) begin
                divider <= 0;
                bck <= 0;
                // I2S changes WS when the *previous* word's LSB is sent.
                // MSB follows one BCLK later. PCM5102A samples on rising BCLK.
                dout <= shift_word[31];
                bit_slot <= bit_slot + 1'b1;
                case (bit_slot)
                    0: begin
                        lrck <= 0;
                        if (!unmute) begin
                            warm_frames <= warm_frames + 1'b1;
                            if (warm_frames == 1023) unmute <= 1;
                        end
                        frame_word <= unmute ? {gained,9'b0} : 32'b0;
                        shift_word <= unmute ? {gained,9'b0} : 32'b0;
                    end
                    32: begin
                        lrck <= 1;
                        shift_word <= frame_word;
                    end
                    default: shift_word <= {shift_word[30:0],1'b0};
                endcase
            end
        end
    end
endmodule

module audio_voice #(parameter [23:0] PHASE_STEP = 24'd93639) (
    input clk, input reset, input frame_start, input gate, input [1:0] timbre,
    output reg signed [17:0] sample
);
    reg [23:0] phase;
    reg [7:0] envelope;
    wire [7:0] fraction = phase[21:14];
    wire [7:0] triangle_bits = (phase[23] ^ phase[22]) ? ~fraction : fraction;
    reg signed [8:0] wave;
    always @* begin
        case (timbre)
            1: wave = phase[23] ? -9'sd180 : 9'sd180; // square
            2: wave = $signed(phase[23:15]);          // sawtooth
            default: wave = $signed({phase[23],triangle_bits});
        endcase
    end
    always @(posedge clk) begin
        if (reset) begin
            phase <= 0;
            envelope <= 0;
            sample <= 0;
        end else begin
            sample <= wave * $signed({1'b0,envelope});
            if (frame_start) begin
                // 64-frame attack and up to 255-frame release.
                if (gate) envelope <= envelope >= 251 ? 8'd255 : envelope + 3'd4;
                else if (envelope != 0) envelope <= envelope - 1'b1;
                if (gate || envelope != 0) phase <= phase + PHASE_STEP;
                else phase <= 0;
            end
        end
    end
endmodule
