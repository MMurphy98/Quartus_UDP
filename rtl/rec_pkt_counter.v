module rec_pkt_counter(
    input              clk         ,    //时钟信号（使用eth_rx_clk）
    input              rst_n       ,    //复位信号，低电平有效
    input              rec_pkt_done,    //接收包完成信号
    output reg [19:0]  pkt_count        // 接收包计数（20 位，十进制显示 0~999999）
);

//检测rec_pkt_done的上升沿
reg rec_pkt_done_d0;
reg rec_pkt_done_d1;
wire rec_pkt_pos;

assign rec_pkt_pos = (~rec_pkt_done_d1) & rec_pkt_done_d0;

//打拍检测上升沿
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rec_pkt_done_d0 <= 1'b0;
        rec_pkt_done_d1 <= 1'b0;
    end
    else begin
        rec_pkt_done_d0 <= rec_pkt_done;
        rec_pkt_done_d1 <= rec_pkt_done_d0;
    end
end

// 计数逻辑：0~999999 后回零，6 位十进制显示
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        pkt_count <= 20'd0;
    else if(rec_pkt_pos) begin
        if(pkt_count == 20'd999999)
            pkt_count <= 20'd0;
        else
            pkt_count <= pkt_count + 1'b1;
    end
end

endmodule