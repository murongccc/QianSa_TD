// 校验后的报告直接生成轨道事件；坐标只在新身份按下时比较，不缓存坐标。
module touch_lane_input #(
    parameter [15:0] X0=16'd2494, X1=16'd5307, X2=16'd8119,
    parameter [15:0] X3=16'd10931, X4=16'd13744, Y0=16'd7584
)(
    input wire clk, input wire rst, input wire enable,
    input wire update_valid,
    input wire [3:0] a_id, input wire a_down, input wire [15:0] a_x,a_y,
    input wire [3:0] b_id, input wire b_down, input wire [15:0] b_x,b_y,
    output reg event_valid, output reg [3:0] press_mask,release_mask,down_mask,
    output reg armed
);
reg [3:0] id0,id1,bind0,bind1;
reg live0,live1;
reg [3:0] next0,next1;
wire [3:0] next_down=next0 | next1;
function [3:0] hit;
    input [15:0] x,y;
    begin
        hit=4'd0;
        if(x>=X0 && x<X4 && y>=Y0)begin
            if(x<X1)hit=4'b0001;
            else if(x<X2)hit=4'b0010;
            else if(x<X3)hit=4'b0100;
            else hit=4'b1000;
        end
    end
endfunction
// 先按编号匹配两个旧接触，允许槽换位、复用及同报告释放/新增。
// 区外接触也保存 live/id（绑定为零），滑入时不得重新判断。
always @* begin
    next0=4'd0;next1=4'd0;
    if(a_down)begin
        if(live0 && a_id==id0)next0=bind0;
        else if(live1 && a_id==id1)next0=bind1;
        else next0=hit(a_x,a_y);
    end
    if(b_down)begin
        if(live0 && b_id==id0)next1=bind0;
        else if(live1 && b_id==id1)next1=bind1;
        else next1=hit(b_x,b_y);
    end
end
always @(posedge clk or posedge rst)begin
    if(rst)begin
        id0<=0;id1<=0;live0<=0;live1<=0;bind0<=0;bind1<=0;
        armed<=0;event_valid<=0;press_mask<=0;release_mask<=0;down_mask<=0;
    end else begin
        event_valid<=0;press_mask<=0;release_mask<=0;
        if(!enable)begin
            armed<=0;live0<=0;live1<=0;bind0<=0;bind1<=0;down_mask<=0;
        end else if(!armed)begin
            // 解析器保持的是最新有效状态，静止手指不会因无报告而被释放。
            if(!a_down && !b_down)armed<=1;
        end else if(update_valid)begin
            id0<=a_id;id1<=b_id;live0<=a_down;live1<=b_down;
            bind0<=next0;bind1<=next1;down_mask<=next_down;
            if(next_down!=down_mask)begin
                event_valid<=1;press_mask<=next_down & ~down_mask;
                release_mask<=down_mask & ~next_down;
            end
        end
    end
end
endmodule
