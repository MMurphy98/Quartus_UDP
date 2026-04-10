//----------------------------------------------------------------------------------------
// Module:     sdram_udp_bridge
// Function:   Bridge between UDP and SDRAM: store RX data to SDRAM, read on command and send via UDP
// Protocol:   Data packet = 520 bytes (130 x int32: 2 pkt_idx + 128 data); Read request = 4 bytes, magic 0x52454144 ("READ")
// 新一轮发送：仅在“READ 之后的首个数据包”或上电首包时清零 written_byte_count、标记首包并拉高 wr_load；
//            PC 一次 write(2M) 会被 MATLAB 拆成多包 512B 发送，同批后续包不重置，累计长度正确，READ 回传整批。
//----------------------------------------------------------------------------------------

module sdram_udp_bridge #(
    parameter ADDR_MIN     = 25'd0,
    parameter ADDR_MAX     = 25'd15999999,
    parameter LEN          = 11'd1024,
    parameter READ_CMD     = 32'h52454144,   // "READ"
    parameter BYTES_PER_PKT = 16'd520
)(
    input             clk_rx,              // RX clock (e.g. ENET0_RX_CLK)
    input             clk_tx,               // TX clock (e.g. ENET0_TX_CLK)
    input             rst_n,                // sync reset, low active

    // UDP receive (from UDP module)
    input             rec_en,
    input      [31:0] rec_data,
    input             rec_pkt_done,
    input      [15:0] rec_byte_num,

    // SDRAM write port (to sdram_top)
    output reg        wr_en,
    output reg [31:0] wr_data,
    output     [24:0] wr_min_addr,
    output     [24:0] wr_max_addr,
    output     [10:0] wr_len,
    output reg        wr_load,

    // SDRAM read port (to sdram_top)
    output reg        rd_en,
    input      [31:0] rd_data,
    output     [24:0] rd_min_addr,
    output reg [24:0] rd_max_addr,
    output     [10:0] rd_len,
    output reg        rd_load,

    input             sdram_init_done,

    // Send FIFO (write side: bridge writes SDRAM read data)
    output reg        send_fifo_wrreq,
    output     [31:0] send_fifo_din,        // tie to rd_data in top

    // UDP send (to UDP module)
    output reg        tx_start_en,
    output reg [15:0] tx_byte_num,
    input             tx_done,
    input             tx_req,

    // Debug (for LED)
    output reg        sdram_has_data,    // 至少有一包数据已写入 SDRAM
    output reg        read_cmd_recognized // READ 是否被识别
);
    assign wr_min_addr = ADDR_MIN;
    assign wr_max_addr = ADDR_MAX;
    assign wr_len      = LEN;
    assign rd_min_addr = 25'd0;
    assign rd_len      = LEN;
    localparam WORDS_DATA_PER_PKT = 8'd128;   // 每包 2 字序号 + 128 字数据，共 130 字 = 520 字节
    localparam RD_LATENCY         = 3'd1;      // SDRAM 读 FIFO 有效数据滞后拍数（仅第 1 拍无效，跳过 1 拍）
    assign send_fifo_din = (rd_cyc_cnt <= 9'd1) ? pkt_idx : rd_data;

    // ---------- RX domain (clk_rx): packet buffer and write to SDRAM ----------
    reg [31:0] pkt_buf [0:127];
    reg  [6:0] wr_ptr;
    reg  [6:0] drain_cnt;
    reg [31:0] first_word_rx;
    reg [31:0] written_byte_count;
    reg        first_packet_of_batch;   // 本轮第一包，写 SDRAM 时拉高 wr_load
    reg        after_read;             // 刚执行过 READ，下一包数据视为新一轮（PC 一次 write 多包中的首包）
    reg        do_read;
    reg [31:0] send_byte_count_hold;
    reg [1:0]  do_read_hold;   // hold do_read for 3 RX cycles so TX domain can capture

    localparam RX_IDLE   = 2'd0;
    localparam RX_FILL   = 2'd1;
    localparam RX_DRAIN  = 2'd2;
    reg [1:0] rx_state;

    wire is_read_cmd = rec_pkt_done && (rec_byte_num == 16'd4) && (first_word_rx == READ_CMD);

    always @(posedge clk_rx or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr     <= 7'd0;
            first_word_rx <= 32'd0;
            written_byte_count <= 32'd0;
            do_read    <= 1'b0;
            send_byte_count_hold <= 32'd0;
            rx_state   <= RX_IDLE;
            wr_en      <= 1'b0;
            wr_data    <= 32'd0;
            wr_load    <= 1'b0;
            drain_cnt  <= 7'd0;
            sdram_has_data <= 1'b0;
            do_read_hold   <= 2'd0;
            read_cmd_recognized <= 1'b0;
            first_packet_of_batch <= 1'b0;
            after_read <= 1'b1;        // 上电后第一批数据也按“新一轮”处理
        end else begin
            wr_load <= 1'b0;
            wr_en   <= 1'b0;
            wr_data <= 32'd0;

            case (rx_state)
                RX_IDLE: begin
                    wr_ptr <= 7'd0;
                    if (rec_en) begin
                        pkt_buf[0] <= rec_data;
                        first_word_rx <= rec_data;
                        wr_ptr <= 7'd1;
                        // 4-byte packet: rec_en and rec_pkt_done fire same cycle; check READ here or we miss it
                        if (rec_pkt_done && (rec_byte_num == 16'd4) && (rec_data == READ_CMD)) begin
                            do_read <= 1'b1;
                            do_read_hold <= 2'd3;
                            send_byte_count_hold <= written_byte_count;
                            read_cmd_recognized <= 1'b1;
                            sdram_has_data <= 1'b0;   // 读走后熄灭，下一轮 send 写首包时再亮
                            after_read <= 1'b1;   // 下次收到数据包时视为新一轮（PC 一次 write 多包的首包）
                            rx_state <= RX_IDLE;
                            wr_ptr   <= 7'd0;
                        end else begin
                            // 仅“READ 之后的首包”或上电首包：清零累计、标记首包；同批后续包不重置
                            if (after_read) begin
                                written_byte_count <= 32'd0;
                                first_packet_of_batch <= 1'b1;
                                after_read <= 1'b0;
                                read_cmd_recognized <= 1'b0;   // 新一轮数据到来时熄灭，下次 READ 时再亮
                            end else
                                first_packet_of_batch <= 1'b0;
                            rx_state <= RX_FILL;
                        end
                    end
                end

                RX_FILL: begin
                    if (rec_en) begin
                        pkt_buf[wr_ptr] <= rec_data;
                        wr_ptr <= wr_ptr + 1'b1;
                    end
                    if (rec_pkt_done) begin
                        if (is_read_cmd) begin
                            do_read <= 1'b1;
                            do_read_hold <= 2'd3;   // hold do_read for 3 RX cycles
                            send_byte_count_hold <= written_byte_count;
                            read_cmd_recognized <= 1'b1;
                            sdram_has_data <= 1'b0;   // 读走后熄灭
                            after_read <= 1'b1;     // 下次数据包为新一轮首包
                            rx_state <= RX_IDLE;
                            wr_ptr   <= 7'd0;
                        end else begin
                            drain_cnt <= 7'd0;
                            rx_state  <= RX_DRAIN;
                        end
                    end
                end

                RX_DRAIN: begin
                    if (drain_cnt == 7'd0)
                        wr_load <= first_packet_of_batch;   // 本轮第一包：复位写地址到 wr_min_addr，从 0 写起
                    wr_en   <= 1'b1;
                    wr_data <= pkt_buf[drain_cnt];
                    drain_cnt <= drain_cnt + 1'b1;
                    if (drain_cnt == 7'd127) begin
                        written_byte_count <= written_byte_count + {16'd0, rec_byte_num};
                        first_packet_of_batch <= 1'b0;     // 本包写完，后续包不再复位写地址
                        sdram_has_data <= 1'b1;
                        rx_state <= RX_IDLE;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase

            // Hold do_read for do_read_hold cycles so TX domain can capture (CDC)
            if (do_read_hold != 2'd0) begin
                do_read_hold <= do_read_hold - 2'd1;
                do_read      <= 1'b1;
            end else if (!is_read_cmd)
                do_read      <= 1'b0;
        end
    end

    // ---------- Sync do_read and send_byte_count to TX domain (2-ff per bit for 32-bit) ----------
    reg do_read_sync1, do_read_sync2;
    reg do_read_sync2_d1;
    wire do_read_pos = do_read_sync2 && !do_read_sync2_d1;

    reg [31:0] send_byte_count_sync1, send_byte_count_sync2;
    always @(posedge clk_tx or negedge rst_n) begin
        if (!rst_n) begin
            do_read_sync1    <= 1'b0;
            do_read_sync2    <= 1'b0;
            do_read_sync2_d1 <= 1'b0;
            send_byte_count_sync1 <= 32'd0;
            send_byte_count_sync2 <= 32'd0;
        end else begin
            do_read_sync1    <= do_read;
            do_read_sync2    <= do_read_sync1;
            do_read_sync2_d1 <= do_read_sync2;
            send_byte_count_sync1 <= send_byte_count_hold;
            send_byte_count_sync2 <= send_byte_count_sync1;
        end
    end

    reg [31:0] send_byte_count_tx;
    always @(posedge clk_tx or negedge rst_n) begin
        if (!rst_n)
            send_byte_count_tx <= 32'd0;
        else if (tx_state == TX_CAPTURE && capture_cycle)
            send_byte_count_tx <= send_byte_count_sync2;
    end

    // ---------- TX domain: read SDRAM and send via UDP ----------
    // TX_CAPTURE: delay 2 cycles so send_byte_count_sync2 is stable (avoids CDC race with do_read)
    localparam TX_IDLE       = 3'd0;
    localparam TX_CAPTURE    = 3'd1;   // wait 2 cycles then capture send_byte_count_sync2, go to TX_RD_REQ
    localparam TX_RD_REQ     = 3'd2;   // assert rd_en for 128 cycles
    localparam TX_NEXT_PKT   = 3'd3;   // assert tx_start_en
    localparam TX_WAIT_TX    = 3'd4;   // wait tx_done
    localparam TX_DONE       = 3'd5;
    // 包间/批间延时已注释，发完一包直接发下一包
    // localparam TX_PKT_GAP    = 3'd6;   // 包间延时 + 每 7816 包后 1 s 批间隔（clk_tx=25MHz）
    // localparam PKT_GAP_CYCLES   = 16'd10000;   // 每包后延时 ≈ 0.4 ms
    // localparam PKTS_PER_BATCH   = 13'd7816;
    // localparam BATCH_GAP_CYCLES = 25'd25000000; // 每批后追加 1 s @ 25 MHz

    reg [2:0]  tx_state;   // IDLE, CAPTURE, RD_REQ, NEXT_PKT, WAIT_TX, DONE
    // reg [24:0] gap_cnt;     // 包间或批间延时计数
    // reg [12:0] batch_cnt;  // 当前批内已发包数 1..7816
    reg        capture_cycle;   // 0 = first cycle in TX_CAPTURE, 1 = second cycle
    reg [8:0]  rd_cyc_cnt;     // 0..words_this_pkt，每包先 1 字序号再 words_this_pkt 字数据
    reg [3:0]  lat_cnt;
    reg [31:0] words_to_send;
    reg [31:0] words_sent;
    reg [15:0] pkt_byte_num;
    reg        rd_en_d1;
    reg [31:0] pkt_idx;        // 当前包序号（从 1 起始），发往 PC 用于重排
    reg [7:0]  words_this_pkt; // 本包 SDRAM 字数（1..128），首包时在 rd_cyc_cnt==0 置位

    always @(posedge clk_tx or negedge rst_n) begin
        if (!rst_n) begin
            tx_state        <= TX_IDLE;
            capture_cycle   <= 1'b0;
            rd_en           <= 1'b0;
            rd_load         <= 1'b0;
            rd_max_addr     <= 25'd0;
            send_fifo_wrreq <= 1'b0;
            tx_start_en     <= 1'b0;
            tx_byte_num     <= 16'd0;
            rd_cyc_cnt      <= 9'd0;
            lat_cnt         <= 4'd0;
            words_to_send   <= 32'd0;
            words_sent      <= 32'd0;
            rd_en_d1        <= 1'b0;
            pkt_idx         <= 32'd1;   // 包序号从 1 开始
            words_this_pkt  <= 8'd128;
            // gap_cnt         <= 25'd0;
            // batch_cnt       <= 13'd1;
        end else begin
            rd_en_d1 <= rd_en;
            send_fifo_wrreq <= 1'b0;
            tx_start_en <= 1'b0;
            rd_load <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    rd_en <= 1'b0;
                    capture_cycle <= 1'b0;
                    if (do_read_pos && sdram_init_done)
                        tx_state <= TX_CAPTURE;
                end

                TX_CAPTURE: begin
                    rd_en <= 1'b0;
                    if (!capture_cycle) begin
                        capture_cycle <= 1'b1;   // first cycle: just wait
                    end else begin
                        // 协议：每包固定 128 个数据字，将总字数向上取整为 128 的倍数
                        words_to_send   <= ((send_byte_count_sync2 >> 2) + 32'd127) / 32'd128 * 32'd128;
                        words_sent      <= 32'd0;
                        rd_max_addr     <= ((send_byte_count_sync2 >> 2) + 32'd127) / 32'd128 * 32'd128;
                        rd_load         <= 1'b1;
                        rd_cyc_cnt      <= 9'd0;
                        pkt_idx         <= 32'd1;   // 包序号从 1 开始
                        words_this_pkt  <= 8'd128;
                        // batch_cnt       <= 13'd1;
                        tx_state        <= TX_RD_REQ;
                        capture_cycle   <= 1'b0;
                    end
                end

                TX_RD_REQ: begin
                    if (!sdram_init_done)
                        tx_state <= TX_IDLE;
                    else if (words_sent >= words_to_send)
                        tx_state <= TX_DONE;
                    else begin
                        if (rd_cyc_cnt == 9'd0)
                            words_this_pkt <= 8'd128;
                        // 仅首包(rd_load 后)需跳过 RD_LATENCY 拍无效数据；第二包起 FIFO 已连续，不再跳过
                        send_fifo_wrreq <= (rd_cyc_cnt <= 9'd1) ||
                            (words_sent == 32'd0 ? (rd_cyc_cnt >= 9'd3 + RD_LATENCY && rd_cyc_cnt <= words_this_pkt + 9'd2 + RD_LATENCY)
                                                 : (rd_cyc_cnt >= 9'd3 && rd_cyc_cnt <= words_this_pkt + 9'd2));
                        rd_en <= (words_sent == 32'd0)
                            ? (rd_cyc_cnt >= 9'd2 && rd_cyc_cnt < words_this_pkt + 9'd2 + RD_LATENCY)
                            : (rd_cyc_cnt >= 9'd2 && rd_cyc_cnt < words_this_pkt + 9'd2);
                        if (rd_cyc_cnt == (words_sent == 32'd0 ? words_this_pkt + 9'd2 + RD_LATENCY : words_this_pkt + 9'd2)) begin
                            rd_en <= 1'b0;
                            lat_cnt <= 4'd0;
                            tx_state <= TX_NEXT_PKT;
                            rd_cyc_cnt <= 9'd0;
                        end else
                            rd_cyc_cnt <= rd_cyc_cnt + 9'd1;
                    end
                end

                TX_NEXT_PKT: begin
                    words_sent <= words_sent + {25'd0, words_this_pkt};
                    tx_start_en <= 1'b1;
                    tx_byte_num <= (9'd2 + words_this_pkt) << 2;   // (2+128)*4=520：两字序号 + 128 字数据
                    pkt_idx <= pkt_idx + 32'd1;
                    tx_state <= TX_WAIT_TX;
                end

                TX_WAIT_TX: begin
                    if (tx_done) begin
                        if (words_sent >= words_to_send)
                            tx_state <= TX_DONE;
                        else begin
                            // 包间/批间延时已注释：直接发下一包
                            // if (batch_cnt == PKTS_PER_BATCH) begin
                            //     gap_cnt   <= PKT_GAP_CYCLES + BATCH_GAP_CYCLES;
                            //     batch_cnt <= 13'd1;
                            // end else begin
                            //     gap_cnt   <= PKT_GAP_CYCLES;
                            //     batch_cnt <= batch_cnt + 13'd1;
                            // end
                            // tx_state <= TX_PKT_GAP;
                            tx_state <= TX_RD_REQ;
                        end
                    end
                end

                // TX_PKT_GAP: begin
                //     if (gap_cnt == 25'd0)
                //         tx_state <= TX_RD_REQ;
                //     else
                //         gap_cnt <= gap_cnt - 25'd1;
                // end

                TX_DONE: begin
                    tx_state <= TX_IDLE;
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

endmodule