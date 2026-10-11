// 解析器输出保持到下一次更新；115200 baud 的字节间隔也远大于本模块 13 拍处理时间。
// 两点及六个边界共用一个比较器，不缓存原始坐标，也不依赖视频帧率。
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
reg [3:0] id0,id1,bind0,bind1,first_binding;
reg live0,live1,busy,point,in_area;
reg [2:0] boundary;
reg [1:0] lane;
reg [15:0] threshold;
wire y_axis=boundary==3'd5;
wire [15:0] coordinate=point ? (y_axis ? b_y : b_x) : (y_axis ? a_y : a_x);
wire at_boundary=coordinate>=threshold;
wire [3:0] point_id=point ? b_id : a_id;
wire point_down=point ? b_down : a_down;
reg [3:0] binding;
wire [3:0] next_down=first_binding | binding;
// 常量表选择只有三位索引；唯一的宽比较器供两点、全部边界复用。
always @*begin
    case(boundary)
        3'd0:threshold=X0;3'd1:threshold=X1;3'd2:threshold=X2;
        3'd3:threshold=X3;3'd4:threshold=X4;default:threshold=Y0;
    endcase
    binding=4'd0;
    if(point_down)begin
        if(live0 && point_id==id0)binding=bind0;
        else if(live1 && point_id==id1)binding=bind1;
        else if(in_area && at_boundary)binding=4'b0001 << lane;
    end
end
always @(posedge clk or posedge rst)begin
    if(rst)begin
        id0<=0;id1<=0;live0<=0;live1<=0;bind0<=0;bind1<=0;
        busy<=0;point<=0;boundary<=0;lane<=0;in_area<=0;first_binding<=0;
        armed<=0;event_valid<=0;press_mask<=0;release_mask<=0;down_mask<=0;
    end else begin
        event_valid<=0;press_mask<=0;release_mask<=0;
        if(!enable)begin
            armed<=0;busy<=0;live0<=0;live1<=0;bind0<=0;bind1<=0;down_mask<=0;
        end else if(!armed)begin
            // 使用解析器最新有效状态；不依据报告超时释放静止手指。
            if(!a_down && !b_down)armed<=1;
        end else if(busy)begin
            case(boundary)
                3'd0:begin in_area<=at_boundary;lane<=0;boundary<=3'd1;end
                3'd1,3'd2,3'd3:begin
                    if(at_boundary)lane<=boundary[1:0];
                    boundary<=boundary+3'd1;
                end
                3'd4:begin in_area<=in_area && !at_boundary;boundary<=3'd5;end
                3'd5:begin
                    if(!point)begin first_binding<=binding;point<=1;boundary<=0;end
                    else begin
                        busy<=0;
                        // 两点编号/按住状态由解析器保持；旧身份在两点处理完成前不修改。
                        id0<=a_id;id1<=b_id;live0<=a_down;live1<=b_down;
                        bind0<=first_binding;bind1<=binding;down_mask<=next_down;
                        if(next_down!=down_mask)begin
                            event_valid<=1;press_mask<=next_down & ~down_mask;
                            release_mask<=down_mask & ~next_down;
                        end
                    end
                end
                default:begin busy<=0;boundary<=0;end
            endcase
        end else if(update_valid)begin
            busy<=1;point<=0;boundary<=0;
        end
    end
end
endmodule
