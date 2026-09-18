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
localparam ST_IDLE=4'd0, ST_DIV_X_INIT=4'd1, ST_DIV_X_RUN=4'd2,
           ST_DIV_Y_INIT=4'd3, ST_DIV_Y_RUN=4'd4, ST_FILL=4'd5,
           ST_READ0=4'd6, ST_READ1=4'd7, ST_READ2=4'd8,
           ST_HORIZ=4'd9, ST_VERT=4'd10, ST_PACK=4'd11,
           ST_EMIT=4'd12, ST_DONE=4'd13, ST_CHECK=4'd14,
           ST_CHECK_ROWS=4'd15;

reg [3:0] state;
reg [15:0] sw,sh,fill_col,next_row;
reg [15:0] required_row;
reg [9:0] out_x,out_y;
reg [31:0] x_fp,y_fp,x_step,y_step;
reg [15:0] x_rem_step,y_rem_step,x_phase,y_phase;
// Register both interpolation weights before the multiplier stages.  Without
// this boundary, a coordinate phase accumulator, subtractor and multiplier
// are packed into the same 100 MHz path.
reg [8:0] fx_inv_q,fx_weight_q,fy_inv_q,fy_weight_q;
reg [23:0] p00_q,p01_q,p10_q,p11_q;
reg [17:0] h0_r,h0_g,h0_b,h1_r,h1_g,h1_b;
reg [27:0] v_r,v_g,v_b;
reg last_q,frame_last_q;

// A shared sequential divider computes the coordinate step only once per
// frame.  Per-pixel mapping is then just fixed-point addition.
reg [31:0] div_dividend,div_quotient;
reg [15:0] div_divisor;
reg [16:0] div_remainder;
reg [5:0] div_bit;
wire [16:0] div_shift_remainder={div_remainder[15:0],div_dividend[div_bit]};
wire div_subtract=(div_shift_remainder>={1'b0,div_divisor});
wire [16:0] div_next_remainder=div_subtract ?
    (div_shift_remainder-{1'b0,div_divisor}):div_shift_remainder;

wire [31:0] x_fp_eff=(out_x==OUT_WIDTH-1)?{sw-1'b1,16'h0000}:x_fp;
wire [31:0] y_fp_eff=(out_y==OUT_HEIGHT-1)?{sh-1'b1,16'h0000}:y_fp;
wire [15:0] sx0=x_fp_eff[31:16], sy0=y_fp_eff[31:16];
wire [15:0] sx1=(sx0>=sw-1'b1)?sx0:(sx0+1'b1);
wire [15:0] sy1=(sy0>=sh-1'b1)?sy0:(sy0+1'b1);
wire [7:0] fx=x_fp_eff[15:8], fy=y_fp_eff[15:8];
wire [16:0] x_phase_sum={1'b0,x_phase}+{1'b0,x_rem_step};
wire x_phase_carry=(x_phase_sum>=OUT_WIDTH-1);
wire [16:0] y_phase_sum={1'b0,y_phase}+{1'b0,y_rem_step};
wire y_phase_carry=(y_phase_sum>=OUT_HEIGHT-1);
wire [31:0] y_fp_next=(out_y==OUT_HEIGHT-2)?{sh-1'b1,16'h0000}:
    (y_fp+y_step+y_phase_carry);

// Port A is the PDPW write port.  The IP fixes wea=1 in this mode; cea is
// therefore the actual write qualifier and is asserted only on src handshakes.
wire [23:0] line_even_dout,line_odd_dout;
wire linebuf_write=src_valid&&src_ready;
wire [10:0] linebuf_read_addr=(state==ST_READ0)?sx0[10:0]:sx1[10:0];
wire [23:0] top_dout=sy0[0]?line_odd_dout:line_even_dout;
wire [23:0] bottom_dout=sy1[0]?line_odd_dout:line_even_dout;

scaler_linebuf_even_ip u_line_even(
    .dia(src_pixel),.addra(fill_col[10:0]),.cea(linebuf_write&&!next_row[0]),.clka(clk),
    .dob(line_even_dout),.addrb(linebuf_read_addr),.clkb(clk),.rstb(rst)
);
scaler_linebuf_odd_ip u_line_odd(
    .dia(src_pixel),.addra(fill_col[10:0]),.cea(linebuf_write&&next_row[0]),.clka(clk),
    .dob(line_odd_dout),.addrb(linebuf_read_addr),.clkb(clk),.rstb(rst)
);

function [7:0] round_interp;
 input [27:0] value;
 reg [28:0] rounded;
 begin
  rounded={1'b0,value}+29'd32768;
  round_interp=rounded[23:16];
 end
endfunction
// Do not accept the first pixel of the following row after the two source
// rows needed for the active output line are complete.  The same RAM is
// reused for rows two apart, so accepting that pixel would overwrite a corner
// before it has been interpolated.
assign src_ready=(state==ST_FILL)&&(fill_col<sw);

always @(posedge clk or posedge rst) begin
 if(rst) begin
  state<=ST_IDLE;sw<=1;sh<=1;fill_col<=0;next_row<=0;required_row<=0;out_x<=0;out_y<=0;
  x_fp<=0;y_fp<=0;x_step<=0;y_step<=0;x_rem_step<=0;y_rem_step<=0;x_phase<=0;y_phase<=0;
  fx_inv_q<=0;fx_weight_q<=0;fy_inv_q<=0;fy_weight_q<=0;
  p00_q<=0;p01_q<=0;p10_q<=0;p11_q<=0;
  h0_r<=0;h0_g<=0;h0_b<=0;h1_r<=0;h1_g<=0;h1_b<=0;v_r<=0;v_g<=0;v_b<=0;
  last_q<=0;frame_last_q<=0;
  dst_valid<=0;dst_pixel<=0;dst_last<=0;dst_frame_last<=0;dst_x<=0;dst_y<=0;
  busy<=0;done<=0;div_dividend<=0;div_quotient<=0;div_divisor<=0;div_remainder<=0;div_bit<=0;
 end else begin
  done<=0;
  if(abort) begin
   state<=ST_IDLE;busy<=0;dst_valid<=0;dst_last<=0;dst_frame_last<=0;
  end else case(state)
   ST_IDLE: begin
    busy<=0;dst_valid<=0;
    if(start&&src_width!=0&&src_height!=0&&src_width<=MAX_WIDTH&&src_height<=MAX_HEIGHT) begin
     sw<=src_width;sh<=src_height;fill_col<=0;next_row<=0;out_x<=0;out_y<=0;x_fp<=0;y_fp<=0;x_step<=0;y_step<=0;x_rem_step<=0;y_rem_step<=0;x_phase<=0;y_phase<=0;busy<=1;
     if(src_width<=1) state<=ST_DIV_Y_INIT; else state<=ST_DIV_X_INIT;
    end
   end
   ST_DIV_X_INIT: begin
    div_dividend<={sw-1'b1,16'h0000};div_divisor<=OUT_WIDTH-1;div_remainder<=0;div_quotient<=0;div_bit<=31;state<=ST_DIV_X_RUN;
   end
   ST_DIV_X_RUN: begin
    div_remainder<=div_next_remainder;div_quotient[div_bit]<=div_subtract;
    if(div_bit==0) begin
     x_step<={div_quotient[31:1],div_subtract};x_rem_step<=div_next_remainder[15:0];state<=ST_DIV_Y_INIT;
    end else div_bit<=div_bit-1'b1;
   end
   ST_DIV_Y_INIT: begin
    if(sh<=1) begin y_step<=0;y_rem_step<=0;state<=ST_CHECK;end
    else begin div_dividend<={sh-1'b1,16'h0000};div_divisor<=OUT_HEIGHT-1;div_remainder<=0;div_quotient<=0;div_bit<=31;state<=ST_DIV_Y_RUN;end
   end
   ST_DIV_Y_RUN: begin
    div_remainder<=div_next_remainder;div_quotient[div_bit]<=div_subtract;
    if(div_bit==0) begin
     y_step<={div_quotient[31:1],div_subtract};y_rem_step<=div_next_remainder[15:0];state<=ST_CHECK;
    end else div_bit<=div_bit-1'b1;
   end
   ST_FILL: begin
    busy<=1;
    if(linebuf_write) begin
     if(src_last||fill_col+1'b1>=sw) begin
      fill_col<=0;next_row<=next_row+1'b1;
      if(next_row>=sy1) state<=ST_READ0;
     end else fill_col<=fill_col+1'b1;
    end
   end
   // Check row availability in a state where the source cannot handshake.
   // This removes the output-coordinate comparison from the line-buffer write
   // enable path and prevents accepting a pixel from the row after sy1.
   ST_CHECK:begin
    busy<=1;required_row<=sy1;state<=ST_CHECK_ROWS;
   end
   ST_CHECK_ROWS:begin
    busy<=1;
    if(next_row>required_row)state<=ST_READ0;else state<=ST_FILL;
   end
   // B-port OUTREG: read x0, capture/request x1, then capture x1.
   ST_READ0: begin
    busy<=1;
    fx_inv_q<=9'd256-{1'b0,fx}; fx_weight_q<={1'b0,fx};
    fy_inv_q<=9'd256-{1'b0,fy}; fy_weight_q<={1'b0,fy};
    last_q<=(out_x==OUT_WIDTH-1);frame_last_q<=(out_x==OUT_WIDTH-1)&&(out_y==OUT_HEIGHT-1);state<=ST_READ1;
   end
   ST_READ1: begin
    busy<=1;p00_q<=top_dout;p10_q<=bottom_dout;state<=ST_READ2;
   end
   ST_READ2: begin
    busy<=1;p01_q<=top_dout;p11_q<=bottom_dout;state<=ST_HORIZ;
   end
   // Split bilinear interpolation across two multiplier stages.  This keeps
   // the 100 MHz SD/scaler domain from containing two cascaded multiplies.
   ST_HORIZ: begin
    busy<=1;
    h0_r<=p00_q[23:16]*fx_inv_q+p01_q[23:16]*fx_weight_q;
    h0_g<=p00_q[15:8]*fx_inv_q+p01_q[15:8]*fx_weight_q;
    h0_b<=p00_q[7:0]*fx_inv_q+p01_q[7:0]*fx_weight_q;
    h1_r<=p10_q[23:16]*fx_inv_q+p11_q[23:16]*fx_weight_q;
    h1_g<=p10_q[15:8]*fx_inv_q+p11_q[15:8]*fx_weight_q;
    h1_b<=p10_q[7:0]*fx_inv_q+p11_q[7:0]*fx_weight_q;
    state<=ST_VERT;
   end
   ST_VERT: begin
    busy<=1;
    v_r<=h0_r*fy_inv_q+h1_r*fy_weight_q;
    v_g<=h0_g*fy_inv_q+h1_g*fy_weight_q;
    v_b<=h0_b*fy_inv_q+h1_b*fy_weight_q;
    state<=ST_PACK;
   end
   ST_PACK: begin
    busy<=1;
    dst_pixel<={round_interp(v_r),round_interp(v_g),round_interp(v_b)};
    dst_x<=out_x;dst_y<=out_y;dst_last<=last_q;dst_frame_last<=frame_last_q;dst_valid<=1;state<=ST_EMIT;
   end
   ST_EMIT: if(dst_valid&&dst_ready) begin
    dst_valid<=0;dst_last<=0;dst_frame_last<=0;
    if(frame_last_q) state<=ST_DONE;
    else if(last_q) begin
     out_x<=0;out_y<=out_y+1'b1;x_fp<=0;x_phase<=0;y_fp<=y_fp_next;
     if(out_y==OUT_HEIGHT-2) y_phase<=0;
     else if(y_phase_carry) y_phase<=y_phase_sum-(OUT_HEIGHT-1);
     else y_phase<=y_phase_sum[15:0];
     // Re-evaluate sy1 after out_y/y_fp advance.  ST_FILL immediately moves
     // to ST_READ0 when both required rows are already resident.
     state<=ST_CHECK;
    end else begin
     out_x<=out_x+1'b1;
     if(out_x==OUT_WIDTH-2) begin x_fp<={sw-1'b1,16'h0000};x_phase<=0;end
     else begin
      x_fp<=x_fp+x_step+x_phase_carry;
      if(x_phase_carry) x_phase<=x_phase_sum-(OUT_WIDTH-1);
      else x_phase<=x_phase_sum[15:0];
     end
     state<=ST_READ0;
    end
   end
   ST_DONE: begin busy<=0;done<=1;dst_valid<=0;state<=ST_IDLE;end
   default:state<=ST_IDLE;
  endcase
 end
end
endmodule
