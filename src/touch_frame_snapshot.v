// 视频帧开始时请求源域计算快照，sample_valid确认完成后消隐期收回复并整帧保持。
// 源模块必须在sample_valid后保持数据到下一次sample_request，不再复制源域信箱。
// 两域复位由同一个板级复位断言；frame_start 必须位于足够长的视频消隐期。
module touch_frame_snapshot(
    input wire src_clk,input wire src_rst,input wire [39:0] src_packet,input wire sample_valid,
    output reg sample_request,
    input wire dst_clk,input wire dst_rst,input wire frame_start,
    output reg [39:0] frame_packet
);
reg request_toggle,request_meta,request_sync;
reg ack_toggle,ack_meta,ack_sync;
reg waiting_reply;
reg src_pending;
always @(posedge src_clk or posedge src_rst) begin
    if(src_rst)begin request_meta<=1'b0;request_sync<=1'b0;ack_toggle<=1'b0;src_pending<=1'b0;sample_request<=1'b0;end
    else begin
        sample_request<=1'b0;
        request_meta<=request_toggle;request_sync<=request_meta;
        if(!src_pending && request_sync!=ack_toggle)begin sample_request<=1'b1;src_pending<=1'b1;end
        else if(src_pending && sample_valid)begin ack_toggle<=request_sync;src_pending<=1'b0;end
    end
end
always @(posedge dst_clk or posedge dst_rst) begin
    if(dst_rst)begin
        request_toggle<=1'b0;ack_meta<=1'b0;ack_sync<=1'b0;waiting_reply<=1'b0;frame_packet<=40'd0;
    end else begin
        ack_meta<=ack_toggle;ack_sync<=ack_meta;
        if(frame_start && !waiting_reply)begin request_toggle<=~request_toggle;waiting_reply<=1'b1;end
        if(waiting_reply && ack_sync==request_toggle)begin frame_packet<=src_packet;waiting_reply<=1'b0;end
    end
end
endmodule
