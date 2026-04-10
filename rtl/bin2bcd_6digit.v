// 20 位二进制 -> 6 位十进制 BCD（每位 0~9），组合逻辑
module bin2bcd_6digit(
    input  [19:0] bin,
    output [3:0]  digit0,   // 个位
    output [3:0]  digit1,   // 十位
    output [3:0]  digit2,   // 百位
    output [3:0]  digit3,   // 千位
    output [3:0]  digit4,   // 万位
    output [3:0]  digit5    // 十万位
);
    wire [19:0] d10   = bin / 20'd10;
    wire [19:0] d100  = bin / 20'd100;
    wire [19:0] d1000 = bin / 20'd1000;
    wire [19:0] d10000  = bin / 20'd10000;
    wire [19:0] d100000 = bin / 20'd100000;

    assign digit0 = bin     % 20'd10;
    assign digit1 = d10     % 20'd10;
    assign digit2 = d100    % 20'd10;
    assign digit3 = d1000   % 20'd10;
    assign digit4 = d10000  % 20'd10;
    assign digit5 = d100000 % 20'd10;
endmodule
