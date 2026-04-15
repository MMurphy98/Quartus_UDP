//----------------------------------------------------------------------------------------
// Module:     gpio_stream_gen
// Function:   Internal GPIO-like stream generator.
//             - Generates a 12-bit data bus with a valid pulse width of 2 clk cycles.
//             - Data changes during the 2 valid cycles and is captured as one 24-bit sample.
//             - Extends 24-bit to 32-bit by zero/one/sign extension.
//             - Packs 128 words as one pseudo packet for sdram_udp_bridge input.
//             - Uses deterministic counter pattern so host software can verify data integrity.
//----------------------------------------------------------------------------------------

module gpio_stream_gen #(
    parameter VALID_PERIOD_CYCLES = 5'd5,  // Start one valid burst every N cycles
    parameter PAD_MODE            = 2'd0,  // 0: zero-pad, 1: one-pad, 2: sign-extend from bit23
    parameter TOTAL_PKTS          = 32'd78125
)(
    input             clk,
    input             rst_n,
    input             enable,

    output reg        rec_en,
    output reg [31:0] rec_data,
    output reg        rec_pkt_done,
    output reg [15:0] rec_byte_num
);

    localparam WORDS_PER_PKT = 8'd128;
    localparam [15:0] BYTES_PER_PKT = WORDS_PER_PKT * 16'd4;
    localparam [31:0] FLAG_WORD = 32'h7FFF_FFFF; // int32(2147483647)

    reg [4:0]  period_cnt;
    reg [1:0]  valid_phase;
    reg        gpio_valid;
    reg [11:0] gpio_data12;
    reg [23:0] sample_word_counter;

    reg [11:0] first_12b;
    reg        got_first_12b;
    reg [7:0]  word_cnt;
    reg [31:0] pkt_cnt;
    reg        flag_sent;

    wire [23:0] sample_24b = {first_12b, gpio_data12};
    wire [31:0] sample_32b_zero = {8'h00, sample_24b};
    wire [31:0] sample_32b_one  = {8'hFF, sample_24b};
    wire [31:0] sample_32b_sign = {{8{sample_24b[23]}}, sample_24b};

    wire [31:0] sample_32b = (PAD_MODE == 2'd1) ? sample_32b_one :
                             (PAD_MODE == 2'd2) ? sample_32b_sign :
                                                  sample_32b_zero;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            period_cnt     <= 5'd0;
            valid_phase    <= 2'd0;
            gpio_valid     <= 1'b0;
            gpio_data12    <= 12'd0;
            sample_word_counter <= 24'd0;
            first_12b      <= 12'd0;
            got_first_12b  <= 1'b0;
            word_cnt       <= 8'd0;
            pkt_cnt        <= 32'd0;
            flag_sent      <= 1'b0;

            rec_en         <= 1'b0;
            rec_data       <= 32'd0;
            rec_pkt_done   <= 1'b0;
            rec_byte_num   <= BYTES_PER_PKT;
        end else if (!enable) begin
            period_cnt     <= 5'd0;
            valid_phase    <= 2'd0;
            gpio_valid     <= 1'b0;
            gpio_data12    <= 12'd0;
            sample_word_counter <= 24'd0;
            first_12b      <= 12'd0;
            got_first_12b  <= 1'b0;
            word_cnt       <= 8'd0;
            pkt_cnt        <= 32'd0;
            flag_sent      <= 1'b0;

            rec_en         <= 1'b0;
            rec_data       <= 32'd0;
            rec_pkt_done   <= 1'b0;
            rec_byte_num   <= BYTES_PER_PKT;
        end else if (pkt_cnt >= TOTAL_PKTS) begin
            // Reached configured packet budget: stop generating more packets.
            rec_en       <= 1'b0;
            rec_pkt_done <= 1'b0;
            rec_data     <= 32'd0;
        end else begin
            rec_en       <= 1'b0;
            rec_pkt_done <= 1'b0;

            // Generate internal GPIO-like valid/data pattern.
            if (!gpio_valid) begin
                if (period_cnt == VALID_PERIOD_CYCLES - 1'b1) begin
                    period_cnt  <= 5'd0;
                    gpio_valid  <= 1'b1;
                    valid_phase <= 2'd0;

                    // First valid cycle: output upper 12 bits of current sample.
                    gpio_data12 <= sample_word_counter[23:12];
                end else begin
                    period_cnt <= period_cnt + 1'b1;
                end
            end else begin
                // Keep valid high for 2 cycles; update data on each valid cycle.
                if (valid_phase == 2'd0) begin
                    valid_phase <= 2'd1;

                    // Second valid cycle: output lower 12 bits of current sample.
                    gpio_data12 <= sample_word_counter[11:0];
                end else begin
                    gpio_valid  <= 1'b0;
                    valid_phase <= 2'd0;
                end
            end

            // Capture two 12-bit samples when valid is high and emit one 32-bit word.
            if (gpio_valid) begin
                if (!got_first_12b) begin
                    first_12b     <= gpio_data12;
                    got_first_12b <= 1'b1;
                end else begin
                    got_first_12b <= 1'b0;
                    rec_en        <= 1'b1;

                    // Match original UDP test format: emit FLAG as the first word once after enable.
                    if (!flag_sent) begin
                        rec_data   <= FLAG_WORD;
                        flag_sent  <= 1'b1;
                    end else begin
                        rec_data   <= sample_32b;
                        sample_word_counter <= sample_word_counter + 24'd1;
                    end

                    if (word_cnt == WORDS_PER_PKT - 1'b1) begin
                        word_cnt      <= 8'd0;
                        rec_pkt_done  <= 1'b1;
                        rec_byte_num  <= BYTES_PER_PKT;
                        pkt_cnt       <= pkt_cnt + 32'd1;
                    end else begin
                        word_cnt <= word_cnt + 1'b1;
                    end
                end
            end
        end
    end

endmodule
