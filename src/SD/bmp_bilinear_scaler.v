// BMP stream to fixed-resolution bilinear scaler.  Two PDPW ERAMs retain
// alternating source rows; their registered B ports provide corner pixels.
module bmp_bilinear_scaler #(
    parameter integer OUT_WIDTH=640, parameter integer OUT_HEIGHT=480,
    parameter integer MAX_WIDTH=1920, parameter integer MAX_HEIGHT=1080
) (
    input wire clk, input wire rst, input wire start, input wire abort,
    input wire [15:0] src_width, input wire [15:0] src_height,
    input wire src_valid, input wire [23:0] src_pixel,
    input wire src_last, input wire src_frame_last,
    output wire src_ready, input wire dst_ready,
    output reg dst_valid, output reg [23:0] dst_pixel,
    output reg dst_last, output reg dst_frame_last,
    output reg [9:0] dst_x, output reg [9:0] dst_y,
    output reg busy, output reg done
);
localparam ST_IDLE=5'd0, ST_DIV_X_INIT=5'd1, ST_DIV_X_RUN=5'd2,
           ST_DIV_Y_INIT=5'd3, ST_DIV_Y_RUN=5'd4, ST_FILL=5'd5,
           ST_READ0=5'd6, ST_READ1=5'd7, ST_READ2=5'd8,
           ST_H0_BASE=5'd9, ST_H0_ACC=5'd10, ST_H1_BASE=5'd11,
           ST_H1_ACC=5'd12, ST_V_BASE=5'd13, ST_V_ACC=5'd14,
           ST_PACK=5'd15, ST_EMIT=5'd16, ST_DONE=5'd17,
           ST_CHECK=5'd18, ST_CHECK_ROWS=5'd19, ST_VALIDATE=5'd20;

function integer count_width;
 input integer maximum;
 integer remaining;
 begin
  remaining=maximum;count_width=0;
  while(remaining>0) begin remaining=remaining>>1;count_width=count_width+1;end
  if(count_width<1)count_width=1;
 end
endfunction
// 尺寸寄存器需要容纳最大尺寸本身，next_row 还会保存已填完的行数。
localparam integer SRC_X_BITS=count_width(MAX_WIDTH);
localparam integer SRC_Y_BITS=count_width(MAX_HEIGHT);
localparam integer X_FP_BITS=SRC_X_BITS+16;
localparam integer Y_FP_BITS=SRC_Y_BITS+16;
localparam integer X_PHASE_BITS=count_width(OUT_WIDTH-1);
localparam integer Y_PHASE_BITS=count_width(OUT_HEIGHT-1);
localparam integer DIVISOR_BITS=(X_PHASE_BITS>Y_PHASE_BITS)?X_PHASE_BITS:Y_PHASE_BITS;
localparam [X_PHASE_BITS:0] X_DENOM=OUT_WIDTH-1;
localparam [Y_PHASE_BITS:0] Y_DENOM=OUT_HEIGHT-1;

reg [4:0] state;
reg [SRC_X_BITS-1:0] sw,fill_col;
reg [SRC_Y_BITS-1:0] sh,next_row,required_row;
reg [X_PHASE_BITS-1:0] out_x;
reg [Y_PHASE_BITS-1:0] out_y;
reg [X_FP_BITS-1:0] x_fp,x_step;
reg [Y_FP_BITS-1:0] y_fp,y_step;
reg [X_PHASE_BITS-1:0] x_rem_step,x_phase;
reg [Y_PHASE_BITS-1:0] y_rem_step,y_phase;
// Register both interpolation weights before the multiplier stages.  Without
// this boundary, a coordinate phase accumulator, subtractor and multiplier
// are packed into the same 100 MHz path.
reg [8:0] fx_inv_q,fx_weight_q,fy_inv_q,fy_weight_q;
reg [23:0] p00_q,p01_q,p10_q,p11_q;
// 两个权重之和为 256，水平最大 255*256，垂直最大 255*65536。
// 三个阶段的基础乘积不同时存活，复用同一组 RGB 累加输入。
reg [23:0] acc_r,acc_g,acc_b;
wire [35:0] mul_p0,mul_p1,mul_p2;
reg [15:0] h0_r,h0_g,h0_b,h1_r,h1_g,h1_b;
wire [23:0] sum_r=acc_r+mul_p0[23:0];
wire [23:0] sum_g=acc_g+mul_p1[23:0];
wire [23:0] sum_b=acc_b+mul_p2[23:0];
reg [23:0] v_r,v_g,v_b;
reg last_q,frame_last_q;

// Three physical multipliers are shared by all RGB horizontal and vertical
// terms.  The scaler runs only while frames are preloaded, so the additional
// internal cycles do not affect the video output rate.  Keeping the operands
// registered makes the resource-sharing intent unambiguous to synthesis.
reg [17:0] mul_a0,mul_a1,mul_a2;
reg [17:0] mul_b0,mul_b1,mul_b2;


// Do not leave the shared operators as generic '*' expressions: TD may clone
// such expressions while optimizing the state-dependent operand muxes.  These
// three explicit EG4 multiplier primitives are therefore the only DSPs used
// by the scaler arithmetic schedule.
EG_LOGIC_MULT #(
    .INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
    .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
    .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")
) u_mul0 (
    .p(mul_p0),.a(mul_a0),.b(mul_b0),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
    .clk(clk),.rstan(~rst),.rstbn(~rst),.rstpdn(~rst)
);
EG_LOGIC_MULT #(
    .INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
    .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
    .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")
) u_mul1 (
    .p(mul_p1),.a(mul_a1),.b(mul_b1),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
    .clk(clk),.rstan(~rst),.rstbn(~rst),.rstpdn(~rst)
);
EG_LOGIC_MULT #(
    .INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
    .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
    .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")
) u_mul2 (
    .p(mul_p2),.a(mul_a2),.b(mul_b2),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
    .clk(clk),.rstan(~rst),.rstbn(~rst),.rstpdn(~rst)
);

// A shared sequential divider computes the coordinate step only once per
// frame.  Per-pixel mapping is then just fixed-point addition.
localparam integer DIV_INTEGER_BITS=(SRC_X_BITS>SRC_Y_BITS)?SRC_X_BITS:SRC_Y_BITS;
localparam integer DIV_FP_BITS=DIV_INTEGER_BITS+16;
localparam integer DIV_COUNT_BITS=count_width(DIV_FP_BITS-1);
localparam [DIV_COUNT_BITS-1:0] DIV_LAST_BIT=DIV_FP_BITS-1;
// 整数部分从 MSB 移出，后续自动补零；商共用一个写使能顺序移入。
reg [DIV_INTEGER_BITS-1:0] div_integer;
reg [DIV_FP_BITS-2:0] div_quotient;
reg [DIVISOR_BITS-1:0] div_divisor;
reg [DIVISOR_BITS:0] div_remainder;
reg [DIV_COUNT_BITS-1:0] div_bit;
wire [DIVISOR_BITS:0] div_shift_remainder={div_remainder[DIVISOR_BITS-1:0],div_integer[DIV_INTEGER_BITS-1]};
wire div_subtract=(div_shift_remainder>={1'b0,div_divisor});
wire [DIVISOR_BITS:0] div_next_remainder=div_subtract ?
    (div_shift_remainder-{1'b0,div_divisor}):div_shift_remainder;

wire [X_FP_BITS-1:0] x_fp_eff=(out_x==OUT_WIDTH-1)?{sw-1'b1,16'h0000}:x_fp;
wire [Y_FP_BITS-1:0] y_fp_eff=(out_y==OUT_HEIGHT-1)?{sh-1'b1,16'h0000}:y_fp;
wire [SRC_X_BITS-1:0] sx0=x_fp_eff[X_FP_BITS-1:16];
wire [SRC_Y_BITS-1:0] sy0=y_fp_eff[Y_FP_BITS-1:16];
wire [SRC_X_BITS-1:0] sx1=(sx0>=sw-1'b1)?sx0:(sx0+1'b1);
wire [SRC_Y_BITS-1:0] sy1=(sy0>=sh-1'b1)?sy0:(sy0+1'b1);
wire [7:0] fx=x_fp_eff[15:8], fy=y_fp_eff[15:8];
wire [X_PHASE_BITS:0] x_phase_sum={1'b0,x_phase}+{1'b0,x_rem_step};
wire x_phase_carry=(x_phase_sum>=X_DENOM);
wire [Y_PHASE_BITS:0] y_phase_sum={1'b0,y_phase}+{1'b0,y_rem_step};
wire y_phase_carry=(y_phase_sum>=Y_DENOM);
wire [Y_FP_BITS-1:0] y_fp_next=(out_y==OUT_HEIGHT-2)?{sh-1'b1,16'h0000}:
    (y_fp+y_step+y_phase_carry);

// Port A is the PDPW write port.  The IP fixes wea=1 in this mode; cea is
// therefore the actual write qualifier and is asserted only on src handshakes.
wire [23:0] line_even_dout,line_odd_dout;
wire linebuf_write=src_valid&&src_ready;
wire [10:0] linebuf_read_addr=(state==ST_READ0)?sx0:sx1;
wire [10:0] linebuf_write_addr=fill_col;
wire [23:0] top_dout=sy0[0]?line_odd_dout:line_even_dout;
wire [23:0] bottom_dout=sy1[0]?line_odd_dout:line_even_dout;

scaler_linebuf_even_ip u_line_even(
    .dia(src_pixel),.addra(linebuf_write_addr),.cea(linebuf_write&&!next_row[0]),.clka(clk),
    .dob(line_even_dout),.addrb(linebuf_read_addr),.clkb(clk),.rstb(rst)
);
scaler_linebuf_odd_ip u_line_odd(
    .dia(src_pixel),.addra(linebuf_write_addr),.cea(linebuf_write&&next_row[0]),.clka(clk),
    .dob(line_odd_dout),.addrb(linebuf_read_addr),.clkb(clk),.rstb(rst)
);

function [7:0] round_interp;
 input [23:0] value;
 reg [23:0] rounded;
 begin
  // 最大插值结果加半个输出 LSB 后仍小于 2^24。
  rounded=value+24'd32768;
  round_interp=rounded[23:16];
 end
endfunction
// Do not accept the first pixel of the following row after the two source
// rows needed for the active output line are complete.  The same RAM is
// reused for rows two apart, so accepting that pixel would overwrite a corner
// before it has been interpolated.
assign src_ready=(state==ST_FILL)&&(fill_col<sw);

// 内部算术数据仅在既定状态消费；每次消费前均已完整写入。
// 对外状态/输出仍由下方复位状态机控制，abort 后重新经过完整读取与计算序列。
// p00/p01 在相邻两拍消费同一读端口，使用每拍捕获可合并为一组寄存器。
always @(posedge clk) begin
 p00_q<=top_dout;p01_q<=top_dout;
 if(state==ST_READ1) p10_q<=bottom_dout;
 if(state==ST_READ2) p11_q<=bottom_dout;
 fx_inv_q<=9'd256-{1'b0,fx};fx_weight_q<={1'b0,fx};
 fy_inv_q<=9'd256-{1'b0,fy};fy_weight_q<={1'b0,fy};
 // 水平阶段乘积小于 2^16，与原来的高八位补零完全等价。
 acc_r<=mul_p0[23:0];acc_g<=mul_p1[23:0];acc_b<=mul_p2[23:0];
 if(state==ST_H0_ACC) begin h0_r<=sum_r[15:0];h0_g<=sum_g[15:0];h0_b<=sum_b[15:0];end
 h1_r<=sum_r[15:0];h1_g<=sum_g[15:0];h1_b<=sum_b[15:0];
 v_r<=sum_r;v_g<=sum_g;v_b<=sum_b;
 // 操作数仅需在其下一拍消费，非计算状态写零，避免复位和保持使能。
 case(state)
  ST_READ2:begin
   mul_a0<={10'd0,p00_q[23:16]};mul_a1<={10'd0,p00_q[15:8]};mul_a2<={10'd0,p00_q[7:0]};
   mul_b0<={9'd0,fx_inv_q};mul_b1<={9'd0,fx_inv_q};mul_b2<={9'd0,fx_inv_q};
  end
  ST_H0_BASE:begin
   mul_a0<={10'd0,p01_q[23:16]};mul_a1<={10'd0,p01_q[15:8]};mul_a2<={10'd0,p01_q[7:0]};
   mul_b0<={9'd0,fx_weight_q};mul_b1<={9'd0,fx_weight_q};mul_b2<={9'd0,fx_weight_q};
  end
  ST_H0_ACC:begin
   mul_a0<={10'd0,p10_q[23:16]};mul_a1<={10'd0,p10_q[15:8]};mul_a2<={10'd0,p10_q[7:0]};
   mul_b0<={9'd0,fx_inv_q};mul_b1<={9'd0,fx_inv_q};mul_b2<={9'd0,fx_inv_q};
  end
  ST_H1_BASE:begin
   mul_a0<={10'd0,p11_q[23:16]};mul_a1<={10'd0,p11_q[15:8]};mul_a2<={10'd0,p11_q[7:0]};
   mul_b0<={9'd0,fx_weight_q};mul_b1<={9'd0,fx_weight_q};mul_b2<={9'd0,fx_weight_q};
  end
  ST_H1_ACC:begin
   mul_a0<={2'b0,h0_r};mul_a1<={2'b0,h0_g};mul_a2<={2'b0,h0_b};
   mul_b0<={9'd0,fy_inv_q};mul_b1<={9'd0,fy_inv_q};mul_b2<={9'd0,fy_inv_q};
  end
  ST_V_BASE:begin
   mul_a0<={2'b0,h1_r};mul_a1<={2'b0,h1_g};mul_a2<={2'b0,h1_b};
   mul_b0<={9'd0,fy_weight_q};mul_b1<={9'd0,fy_weight_q};mul_b2<={9'd0,fy_weight_q};
  end
  default:begin mul_a0<=18'd0;mul_a1<=18'd0;mul_a2<=18'd0;mul_b0<=18'd0;mul_b1<=18'd0;mul_b2<=18'd0;end
 endcase
end

// 帧工作数据统一无复位：尺寸在 ST_IDLE 锁存，计数与相位在
// ST_VALIDATE 初始化，除法器在各 INIT 状态初始化后才进入 RUN。
// reset/abort 只需使控制状态回到 IDLE；下一帧会覆盖全部可消费数据。
always @(posedge clk) begin
 case(state)
  ST_IDLE:if(start) begin sw<=src_width;sh<=src_height;end
  ST_VALIDATE:begin
   fill_col<=0;next_row<=0;out_x<=0;out_y<=0;x_fp<=0;y_fp<=0;
   x_step<=0;y_step<=0;x_rem_step<=0;y_rem_step<=0;x_phase<=0;y_phase<=0;
  end
  ST_DIV_X_INIT:begin
   div_integer<=sw-1'b1;div_divisor<=OUT_WIDTH-1;div_remainder<=0;
   div_quotient<=0;div_bit<=DIV_LAST_BIT;
  end
  ST_DIV_X_RUN:begin
   div_remainder<=div_next_remainder;div_quotient<={div_quotient[DIV_FP_BITS-3:0],div_subtract};div_integer<=div_integer<<1;
   if(div_bit==0)begin x_step<={div_quotient[X_FP_BITS-2:0],div_subtract};x_rem_step<=div_next_remainder[X_PHASE_BITS-1:0];end
   else div_bit<=div_bit-1'b1;
  end
  ST_DIV_Y_INIT:begin
   if(sh<=1)begin y_step<=0;y_rem_step<=0;end
   else begin div_integer<=sh-1'b1;div_divisor<=OUT_HEIGHT-1;div_remainder<=0;div_quotient<=0;div_bit<=DIV_LAST_BIT;end
  end
  ST_DIV_Y_RUN:begin
   div_remainder<=div_next_remainder;div_quotient<={div_quotient[DIV_FP_BITS-3:0],div_subtract};div_integer<=div_integer<<1;
   if(div_bit==0)begin y_step<={div_quotient[Y_FP_BITS-2:0],div_subtract};y_rem_step<=div_next_remainder[Y_PHASE_BITS-1:0];end
   else div_bit<=div_bit-1'b1;
  end
  ST_FILL:if(linebuf_write)begin
   if(src_last||fill_col+1'b1>=sw)begin fill_col<=0;next_row<=next_row+1'b1;end
   else fill_col<=fill_col+1'b1;
  end
  ST_CHECK:required_row<=sy1;
  ST_READ0:begin last_q<=(out_x==OUT_WIDTH-1);frame_last_q<=(out_x==OUT_WIDTH-1)&&(out_y==OUT_HEIGHT-1);end
  ST_EMIT:if(dst_valid&&dst_ready&&!frame_last_q)begin
   if(last_q)begin
    out_x<=0;out_y<=out_y+1'b1;x_fp<=0;x_phase<=0;y_fp<=y_fp_next;
    if(out_y==OUT_HEIGHT-2)y_phase<=0;
    else if(y_phase_carry)y_phase<=y_phase_sum-Y_DENOM;
    else y_phase<=y_phase_sum[Y_PHASE_BITS-1:0];
   end else begin
    out_x<=out_x+1'b1;
    if(out_x==OUT_WIDTH-2)begin x_fp<={sw-1'b1,16'h0000};x_phase<=0;end
    else begin
     x_fp<=x_fp+x_step+x_phase_carry;
     if(x_phase_carry)x_phase<=x_phase_sum-X_DENOM;
     else x_phase<=x_phase_sum[X_PHASE_BITS-1:0];
    end
   end
  end
  default:begin end
 endcase
end

always @(posedge clk or posedge rst) begin
 if(rst)begin
  state<=ST_IDLE;dst_valid<=0;dst_pixel<=0;dst_last<=0;dst_frame_last<=0;
  dst_x<=0;dst_y<=0;busy<=0;done<=0;
 end else begin
  done<=0;
  if(abort)begin state<=ST_IDLE;busy<=0;dst_valid<=0;dst_last<=0;dst_frame_last<=0;end
  else case(state)
   ST_IDLE:begin busy<=0;dst_valid<=0;if(start)state<=ST_VALIDATE;end
   ST_VALIDATE:begin
    if(sw!=0&&sh!=0&&sw<=MAX_WIDTH&&sh<=MAX_HEIGHT)begin
     busy<=1;if(sw<=1)state<=ST_DIV_Y_INIT;else state<=ST_DIV_X_INIT;
    end else begin busy<=0;state<=ST_IDLE;end
   end
   ST_DIV_X_INIT:state<=ST_DIV_X_RUN;
   ST_DIV_X_RUN:if(div_bit==0)state<=ST_DIV_Y_INIT;
   ST_DIV_Y_INIT:if(sh<=1)state<=ST_CHECK;else state<=ST_DIV_Y_RUN;
   ST_DIV_Y_RUN:if(div_bit==0)state<=ST_CHECK;
   ST_FILL:begin busy<=1;if(linebuf_write && (src_last||fill_col+1'b1>=sw))state<=ST_CHECK;end
   ST_CHECK:begin busy<=1;state<=ST_CHECK_ROWS;end
   ST_CHECK_ROWS:begin busy<=1;if(next_row>required_row)state<=ST_READ0;else state<=ST_FILL;end
   ST_READ0:begin busy<=1;state<=ST_READ1;end
   ST_READ1:begin busy<=1;state<=ST_READ2;end
   ST_READ2:begin busy<=1;state<=ST_H0_BASE;end
   ST_H0_BASE:begin busy<=1;state<=ST_H0_ACC;end
   ST_H0_ACC:begin busy<=1;state<=ST_H1_BASE;end
   ST_H1_BASE:begin busy<=1;state<=ST_H1_ACC;end
   ST_H1_ACC:begin busy<=1;state<=ST_V_BASE;end
   ST_V_BASE:begin busy<=1;state<=ST_V_ACC;end
   ST_V_ACC:begin busy<=1;state<=ST_PACK;end
   ST_PACK:begin
    busy<=1;dst_pixel<={round_interp(v_r),round_interp(v_g),round_interp(v_b)};
    dst_x<=out_x;dst_y<=out_y;dst_last<=last_q;dst_frame_last<=frame_last_q;dst_valid<=1;state<=ST_EMIT;
   end
   ST_EMIT:if(dst_valid&&dst_ready)begin
    dst_valid<=0;dst_last<=0;dst_frame_last<=0;
    if(frame_last_q)state<=ST_DONE;else if(last_q)state<=ST_CHECK;else state<=ST_READ0;
   end
   ST_DONE:begin busy<=0;done<=1;dst_valid<=0;state<=ST_IDLE;end
   default:state<=ST_IDLE;
  endcase
 end
end
endmodule
