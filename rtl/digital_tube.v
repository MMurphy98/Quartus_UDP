module digital_tube(
    input  [3:0] codein,
    output reg[6:0] codeout   //输出的7段码（a,b,c,d,e,f,g）
);

always@(*)
    case(codein)
        4'b0000:begin codeout = ~(7'b0111111); end //0
        4'b0001:begin codeout = ~(7'b0000110); end //1
        4'b0010:begin codeout = ~(7'b1011011); end //2
        4'b0011:begin codeout = ~(7'b1001111); end //3
        4'b0100:begin codeout = ~(7'b1100110); end //4
        4'b0101:begin codeout = ~(7'b1101101); end //5
        4'b0110:begin codeout = ~(7'b1111101); end //6
        4'b0111:begin codeout = ~(7'b0000111); end //7
        4'b1000:begin codeout = ~(7'b1111111); end //8
        4'b1001:begin codeout = ~(7'b1101111); end //9
        4'b1010:begin codeout = ~(7'b1110111); end //A
        4'b1011:begin codeout = ~(7'b1111100); end //B
        4'b1100:begin codeout = ~(7'b0111001); end //C
        4'b1101:begin codeout = ~(7'b1011110); end //D
        4'b1110:begin codeout = ~(7'b1111001); end //E
        4'b1111:begin codeout = ~(7'b1110001); end //F
        default:begin codeout = ~(7'b0000000); end //default 0
    endcase

endmodule