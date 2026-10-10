// 横放、满屏 640x480 的实测标定；四个坐标共用一个器件 DSP，不生成新 IP。
// 输入更新可抢占正在计算的旧快照；只在四项都完成时原子发布输出。
module touch_pixel_mapper #(
    parameter [15:0] X_MIN=16'd96, X_MAX=16'd16144,
    parameter [15:0] Y_MIN=16'd128, Y_MAX=16'd9440,
    parameter [11:0] X_SCALE_Q16=12'd2610, Y_SCALE_Q16=12'd3371,
    parameter integer ATOMIC_OUTPUT=1
)(
    input wire clk, input wire rst, input wire update_valid,
    input wire a_down, input wire [15:0] a_x, input wire [15:0] a_y,
    input wire b_down, input wire [15:0] b_x, input wire [15:0] b_y,
    output reg pixel_valid, output wire [39:0] pixel_packet,output wire busy
);
function integer counter_width;
    input integer value;
    integer remaining;
    begin
        remaining=value-1;counter_width=0;
        while(remaining>0)begin counter_width=counter_width+1;remaining=remaining>>1;end
        if(counter_width==0)counter_width=1;
    end
endfunction
localparam integer MAX_DELTA=(X_MAX-X_MIN)>(Y_MAX-Y_MIN) ? X_MAX-X_MIN : Y_MAX-Y_MIN;
localparam integer DELTA_BITS=counter_width(MAX_DELTA+1);
localparam integer ROUND_BITS=DELTA_BITS+12-16+1;
localparam [1:0] IDLE=2'd0, LOAD=2'd1, PRODUCT=2'd2, STORE=2'd3;
reg [1:0] state, axis;
reg [DELTA_BITS-1:0] operand;
reg y_coefficient;
reg [ROUND_BITS-1:0] rounded;
reg [1:0] down_stage;
reg [9:0] a_x_stage,b_x_stage;
reg [8:0] a_y_stage;
reg [8:0] b_y_stage;
wire [8:0] y_pixel;
assign busy=state!=IDLE;
generate if(ATOMIC_OUTPUT)begin : g_atomic_packet
    reg [39:0] atomic_packet;
    assign pixel_packet=atomic_packet;
    // 只有原子发布配置需要第二份快照；请求/应答配置不建立该可选寄存器。
    always @(posedge clk or posedge rst) begin
        if(rst)atomic_packet<=40'd0;
        else if(!update_valid && state==STORE && axis==2'd3)
            atomic_packet<={down_stage,a_x_stage,a_y_stage,b_x_stage,y_pixel};
    end
end else begin : g_qualified_packet
    // 消隐期请求模式只在pixel_valid后使用；保持到下一次请求，省去重复40位快照。
    assign pixel_packet={down_stage,a_x_stage,a_y_stage,b_x_stage,b_y_stage};
end endgenerate
reg [15:0] raw_coordinate;
wire [15:0] lower_bound=axis[0] ? Y_MIN : X_MIN;
wire [15:0] upper_bound=axis[0] ? Y_MAX : X_MAX;
wire [15:0] clamped_delta=raw_coordinate<lower_bound ? 16'd0 :
    raw_coordinate>upper_bound ? upper_bound-lower_bound : raw_coordinate-lower_bound;
wire [35:0] product;
wire [9:0] x_pixel=rounded>12'd639 ? 10'd639 : rounded[9:0];
assign y_pixel=rounded>12'd479 ? 9'd479 : rounded[8:0];
always @* begin
    case(axis)
        2'd0: raw_coordinate=a_x;
        2'd1: raw_coordinate=a_y;
        2'd2: raw_coordinate=b_x;
        default: raw_coordinate=b_y;
    endcase
end
EG_LOGIC_MULT #(.INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
    .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
    .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")) multiplier(
    .p(product),.a({{(18-DELTA_BITS){1'b0}},operand}),.b({6'd0,(y_coefficient ? Y_SCALE_Q16 : X_SCALE_Q16)}),
    .cea(1'b1),.ceb(1'b1),.cepd(1'b1),.clk(clk),.rstan(!rst),.rstbn(!rst),.rstpdn(!rst));
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE;axis<=2'd0;operand<={DELTA_BITS{1'b0}};y_coefficient<=1'b0;rounded<={ROUND_BITS{1'b0}};
        down_stage<=2'd0;a_x_stage<=10'd0;a_y_stage<=9'd0;b_x_stage<=10'd0;b_y_stage<=9'd0;
        pixel_valid<=1'b0;
    end else begin
        pixel_valid<=1'b0;
        if(update_valid) begin
            // 解析器坐标在下一次 update_valid 前保持；重启计算避免混入两次报告。
            state<=LOAD;axis<=2'd0;down_stage<={a_down,b_down};
        end else case(state)
            IDLE: ;
            LOAD: begin operand<=clamped_delta[DELTA_BITS-1:0];y_coefficient<=axis[0];state<=PRODUCT;end
            PRODUCT: begin
                // 等价于 (product + 32768) >> 16，避免全宽加法器。
                rounded<={1'b0,product[DELTA_BITS+11:16]}+{{(ROUND_BITS-1){1'b0}},product[15]};state<=STORE;
            end
            STORE: begin
                case(axis)
                    2'd0: a_x_stage<=x_pixel;
                    2'd1: a_y_stage<=y_pixel;
                    2'd2: b_x_stage<=x_pixel;
                    default: begin
                        b_y_stage<=y_pixel;
                        pixel_valid<=1'b1;
                    end
                endcase
                if(axis==2'd3)state<=IDLE;
                else begin axis<=axis+2'd1;state<=LOAD;end
            end
            default: state<=IDLE;
        endcase
    end
end
endmodule
