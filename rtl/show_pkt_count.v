// 接收包计数 6 位十进制显示（0~999999）
module show_pkt_count(
    input  [19:0] pkt_count,   // 接收包计数（20 位二进制）
    output [6:0]  HEX0,
    output [6:0]  HEX1,
    output [6:0]  HEX2,
    output [6:0]  HEX3,
    output [6:0]  HEX4,
    output [6:0]  HEX5
);
    wire [3:0] d0, d1, d2, d3, d4, d5;

    bin2bcd_6digit u_bin2bcd (
        .bin    (pkt_count),
        .digit0 (d0),
        .digit1 (d1),
        .digit2 (d2),
        .digit3 (d3),
        .digit4 (d4),
        .digit5 (d5)
    );

    digital_tube u_tube_0 ( .codein(d0), .codeout(HEX0) );
    digital_tube u_tube_1 ( .codein(d1), .codeout(HEX1) );
    digital_tube u_tube_2 ( .codein(d2), .codeout(HEX2) );
    digital_tube u_tube_3 ( .codein(d3), .codeout(HEX3) );
    digital_tube u_tube_4 ( .codein(d4), .codeout(HEX4) );
    digital_tube u_tube_5 ( .codein(d5), .codeout(HEX5) );
endmodule
