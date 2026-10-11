// 两项源域等待记录 + 一项四相握手载荷 + 一项目标域待提交记录。
// 载荷保持到 ack 返回，只有 req/ack 控制位经过双触发同步。
module touch_game_event_bridge(
    input wire src_clk,src_rst, input wire dst_clk,dst_rst,
    input wire enable, // 视频域会话运行，不含渲染 capture 停顿
    output wire src_enable,
    input wire src_valid,input wire [3:0] src_press,src_release,src_down,
    input wire signed [32:0] game_time,
    output reg event_valid,input wire event_ready,
    output reg signed [32:0] event_time,
    output wire [3:0] press_mask,release_mask,down_mask,
    output reg overflow,output wire fault
);
reg enable_meta,enable_sync,ack_meta,ack_sync;
reg req,ack,req_meta,req_sync,fault_meta,fault_sync;
reg [11:0] waiting0,waiting1,payload,pending;
reg [1:0] count;
reg [3:0] committed_down;
reg dst_armed,permit,quiet_meta,quiet_sync;
assign src_enable=enable_sync && !overflow;
assign fault=fault_sync;
assign press_mask=pending[11:8];
assign release_mask=pending[7:4];
// 仅接收边沿可见新状态；反压期间始终使用上一次提交的状态。
assign down_mask=(event_valid && event_ready) ? pending[3:0] : committed_down;
wire launch=enable_sync && !overflow && !req && !ack_sync && count!=0;
wire push=src_valid && enable_sync && !overflow;
always @(posedge src_clk or posedge src_rst)begin
    if(src_rst)begin
        enable_meta<=0;enable_sync<=0;ack_meta<=0;ack_sync<=0;
        req<=0;count<=0;payload<=0;waiting0<=0;waiting1<=0;overflow<=0;
    end else begin
        enable_meta<=permit;enable_sync<=enable_meta;ack_meta<=ack;ack_sync<=ack_meta;
        if(!enable_sync)begin req<=0;count<=0;overflow<=0;end
        else begin
            if(req && ack_sync)req<=0;
            if(launch)begin payload<=waiting0;req<=1;waiting0<=waiting1;end
            if(push)begin
                if(count==2 && !launch)overflow<=1;
                else if(count==0 || (count==1 && launch))waiting0<={src_press,src_release,src_down};
                else waiting1<={src_press,src_release,src_down};
            end
            case({push && (count!=2 || launch),launch})
                2'b10:count<=count+2'd1;
                2'b01:count<=count-2'd1;
                default:;
            endcase
        end
    end
end
always @(posedge dst_clk or posedge dst_rst)begin
    if(dst_rst)begin
        req_meta<=0;req_sync<=0;ack<=0;event_valid<=0;event_time<=0;
        pending<=0;committed_down<=0;dst_armed<=0;permit<=0;quiet_meta<=0;quiet_sync<=0;fault_meta<=0;fault_sync<=0;
    end else begin
        req_meta<=req;req_sync<=req_meta;fault_meta<=overflow;fault_sync<=fault_meta;
        quiet_meta<=!enable_sync && !req && count==0;quiet_sync<=quiet_meta;
        if(!enable)begin ack<=0;event_valid<=0;committed_down<=0;dst_armed<=0;permit<=0;end
        else begin
            // 重新启用先等源域确认停用且队列已清空，防止短暂停消费旧载荷。
            if(!dst_armed && quiet_sync && !req_sync)begin dst_armed<=1;permit<=1;end
            if(!req_sync)ack<=0;
            if(event_valid && event_ready)begin event_valid<=0;committed_down<=pending[3:0];end
            if(dst_armed && req_sync && !ack && !event_valid)begin
                pending<=payload;event_time<=game_time;event_valid<=1;ack<=1;
            end
        end
    end
end
endmodule
