//----------------------------------------------------------------------------------------
// Module:     eth_sdram_top
// Function:   Top: UDP + SDRAM; PC data -> SDRAM, read-request -> SDRAM read -> UDP send.
//----------------------------------------------------------------------------------------

module eth_pc_loop(
    input         CLOCK_50,
    input  [17:0] SW,

    // Ethernet
    input         ENET0_RX_CLK,
    input         ENET0_RX_DV,
    input  [3:0]  ENET0_RX_DATA,
    input         ENET0_TX_CLK,
    output        ENET0_TX_EN,
    output [3:0]  ENET0_TX_DATA,
    output        ENET0_TX_ER,
    output        ENET0_RST_N,

    // SDRAM
    output        DRAM_CLK,
    output        DRAM_CKE,
    output        DRAM_CS_N,
    output        DRAM_RAS_N,
    output        DRAM_CAS_N,
    output        DRAM_WE_N,
    output [1:0]  DRAM_BA,
    output [12:0] DRAM_ADDR,
    inout  [31:0] DRAM_DQ,
    output [3:0]  DRAM_DQM,

	output [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
	output [7:0]  LEDG
);

    parameter BOARD_MAC = 48'h00_11_22_33_44_55;
    parameter BOARD_IP  = {8'd192, 8'd168, 8'd1, 8'd123};
    parameter DES_MAC    = 48'hff_ff_ff_ff_ff_ff;
    parameter DES_IP    = {8'd192, 8'd168, 8'd1, 8'd102};
    parameter GPIO_TOTAL_PKTS = 32'd78125;

    parameter ADDR_MIN = 25'd0;
    parameter ADDR_MAX = 25'd15999999;
    parameter LEN      = 11'd1024;

    wire clk_50m, clk_100m, clk_100m_shift;
    wire locked;
    wire sys_rst_n = rst_n & locked;

    wire udp_rec_pkt_done, udp_rec_en;
    wire [31:0] udp_rec_data;
    wire [15:0] udp_rec_byte_num;

    wire gpio_rec_pkt_done, gpio_rec_en;
    wire [31:0] gpio_rec_data;
    wire [15:0] gpio_rec_byte_num;

    wire rec_pkt_done, rec_en;
    wire [31:0] rec_data;
    wire [15:0] rec_byte_num;
    wire udp_read_cmd;
    wire gpio_gen_en;
    wire tx_done, tx_req;
    wire tx_start_en;
    wire [31:0] tx_data;
    wire [15:0] tx_byte_num;

    wire wr_en, rd_en;
    wire [31:0] wr_data, rd_data, send_fifo_din;
    wire [24:0] wr_min_addr, wr_max_addr, rd_min_addr;
    wire [24:0] rd_max_addr;
    wire [10:0] wr_len, rd_len;
    wire wr_load, rd_load;
    wire sdram_init_done;

    wire sdram_has_data;
    wire read_cmd_recognized;

    wire [19:0] pkt_count;
    wire rst_n = SW[0];
    wire rst_n_pll = SW[1];

    localparam [18:0] SW_DB_MAX = 19'd499999;
    reg sw2_meta, sw2_sync;
    reg sw2_db;
    reg [18:0] sw2_db_cnt;

    assign gpio_gen_en = sw2_db;

    // Debounce SW[2] in ENET0_RX_CLK domain.
    always @(posedge ENET0_RX_CLK or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sw2_meta   <= 1'b0;
            sw2_sync   <= 1'b0;
            sw2_db     <= 1'b0;
            sw2_db_cnt <= 19'd0;
        end else begin
            sw2_meta <= SW[2];
            sw2_sync <= sw2_meta;

            if (sw2_sync == sw2_db)
                sw2_db_cnt <= 19'd0;
            else if (sw2_db_cnt == SW_DB_MAX) begin
                sw2_db     <= sw2_sync;
                sw2_db_cnt <= 19'd0;
            end else
                sw2_db_cnt <= sw2_db_cnt + 1'b1;
        end
    end

    pll_clk u_pll (
        .inclk0 (CLOCK_50),
        .areset (~rst_n_pll),
        .c0     (clk_50m),
        .c1     (clk_100m),
        .c2     (clk_100m_shift),
        .locked (locked)
    );

    udp #(
        .BOARD_MAC (BOARD_MAC),
        .BOARD_IP  (BOARD_IP),
        .DES_MAC   (DES_MAC),
        .DES_IP    (DES_IP)
    ) u_udp (
        .eth_rx_clk   (ENET0_RX_CLK),
        .rst_n        (rst_n),
        .eth_rxdv     (ENET0_RX_DV),
        .eth_rx_data  (ENET0_RX_DATA),
        .eth_tx_clk   (ENET0_TX_CLK),
        .tx_start_en  (tx_start_en),
        .tx_data      (tx_data),
        .tx_byte_num  (tx_byte_num),
        .tx_done      (tx_done),
        .tx_req       (tx_req),
        .rec_pkt_done (udp_rec_pkt_done),
        .rec_en       (udp_rec_en),
        .rec_data     (udp_rec_data),
        .rec_byte_num (udp_rec_byte_num),
        .eth_tx_en    (ENET0_TX_EN),
        .eth_tx_data  (ENET0_TX_DATA),
        .eth_rst_n    (ENET0_RST_N)
    );

    gpio_stream_gen #(
        .VALID_PERIOD_CYCLES (5),
        .PAD_MODE            (2'd0),
        .TOTAL_PKTS          (GPIO_TOTAL_PKTS)
    ) u_gpio_stream_gen (
        .clk          (ENET0_RX_CLK),
        .rst_n        (sys_rst_n),
        .enable       (gpio_gen_en),
        .rec_en       (gpio_rec_en),
        .rec_data     (gpio_rec_data),
        .rec_pkt_done (gpio_rec_pkt_done),
        .rec_byte_num (gpio_rec_byte_num)
    );

    // Keep UDP READ command support, but switch SDRAM write payload source to internal GPIO stream.
    assign udp_read_cmd = udp_rec_en && udp_rec_pkt_done &&
                          (udp_rec_byte_num == 16'd4) && (udp_rec_data == 32'h52454144);

    assign rec_en       = udp_read_cmd ? udp_rec_en       : gpio_rec_en;
    assign rec_data     = udp_read_cmd ? udp_rec_data     : gpio_rec_data;
    assign rec_pkt_done = udp_read_cmd ? udp_rec_pkt_done : gpio_rec_pkt_done;
    assign rec_byte_num = udp_read_cmd ? udp_rec_byte_num : gpio_rec_byte_num;

    sdram_udp_bridge #(
        .ADDR_MIN     (ADDR_MIN),
        .ADDR_MAX     (ADDR_MAX),
        .LEN          (LEN),
        .READ_CMD     (32'h52454144),
        .BYTES_PER_PKT(16'd520)
    ) u_bridge (
        .clk_rx           (ENET0_RX_CLK),
        .clk_tx           (ENET0_TX_CLK),
        .rst_n            (sys_rst_n),
        .rec_en           (rec_en),
        .rec_data         (rec_data),
        .rec_pkt_done     (rec_pkt_done),
        .rec_byte_num     (rec_byte_num),
        .wr_en            (wr_en),
        .wr_data          (wr_data),
        .wr_min_addr      (wr_min_addr),
        .wr_max_addr      (wr_max_addr),
        .wr_len           (wr_len),
        .wr_load          (wr_load),
        .rd_en            (rd_en),
        .rd_data          (rd_data),
        .rd_min_addr      (rd_min_addr),
        .rd_max_addr      (rd_max_addr),
        .rd_len           (rd_len),
        .rd_load          (rd_load),
        .sdram_init_done  (sdram_init_done),
        .send_fifo_wrreq  (send_fifo_wrreq),
        .send_fifo_din    (send_fifo_din),
        .tx_start_en      (tx_start_en),
        .tx_byte_num      (tx_byte_num),
        .tx_done          (tx_done),
        .tx_req           (tx_req),
        .sdram_has_data   (sdram_has_data),
        .read_cmd_recognized (read_cmd_recognized)
    );

    async_fifo_2048x32b u_send_fifo (
        .aclr   (~sys_rst_n),
        .data   (send_fifo_din),
        .wrclk  (ENET0_TX_CLK),
        .wrreq  (send_fifo_wrreq),
        .rdclk  (ENET0_TX_CLK),
        .rdreq  (tx_req),
        .q      (tx_data),
        .rdempty (),
        .wrfull ()
    );

    sdram_top u_sdram_top (
        .ref_clk         (clk_100m),
        .out_clk         (clk_100m_shift),
        .rst_n            (sys_rst_n),
        //用户写端口
        .wr_clk           (ENET0_RX_CLK),
        .wr_en            (wr_en),
        .wr_data          (wr_data),
        .wr_min_addr      (wr_min_addr),
        .wr_max_addr      (wr_max_addr),
        .wr_len           (wr_len),
        .wr_load          (wr_load),
        //用户读端口
        .rd_clk           (ENET0_TX_CLK),
        .rd_en            (rd_en),
        .rd_data          (rd_data),
        .rd_min_addr      (rd_min_addr),
        .rd_max_addr      (rd_max_addr),
        .rd_len           (rd_len),
        .rd_load          (rd_load),
        //用户控制端口
        .sdram_read_valid (1'b1),
        .sdram_init_done  (sdram_init_done),
        //SDRAM 芯片接口
        .sdram_clk        (DRAM_CLK),
        .sdram_cke        (DRAM_CKE),
        .sdram_cs_n       (DRAM_CS_N),
        .sdram_ras_n      (DRAM_RAS_N),
        .sdram_cas_n      (DRAM_CAS_N),
        .sdram_we_n       (DRAM_WE_N),
        .sdram_ba         (DRAM_BA),
        .sdram_addr       (DRAM_ADDR),
        .sdram_data       (DRAM_DQ),
        .sdram_dqm        (DRAM_DQM)
    );

    rec_pkt_counter u_rec_pkt_counter(
        .clk             (ENET0_RX_CLK),
        .rst_n           (SW[0]),
        .rec_pkt_done    (rec_pkt_done),
        .pkt_count       (pkt_count)
    );

    show_pkt_count u_show_pkt_count(
        .pkt_count       (pkt_count),
        .HEX0            (HEX0),
        .HEX1            (HEX1),
        .HEX2            (HEX2),
        .HEX3            (HEX3),
        .HEX4            (HEX4),
        .HEX5            (HEX5)
    );
    assign ENET0_TX_ER = ENET0_TX_CLK;

    assign LEDG[0] = sdram_init_done;     // SDRAM 初始化完成
    assign LEDG[1] = sdram_has_data;      // 至少有一包数据已写入 SDRAM
    assign LEDG[2] = read_cmd_recognized; // READ 是否被识别
endmodule