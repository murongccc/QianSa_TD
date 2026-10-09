`timescale 1ns/1ps
module tb_frame_signature_switch;
reg clk=0; always #5 clk=~clk;
reg rst=1,valid=0,vs=0,req=0,empty=0,pixel=0;
reg [2:0] slot=0;
reg [31:0] data=0;
wire [15:0] under0,under1,wrong0,wrong1;
wire sticky0,sticky1,wrong_sticky0,wrong_sticky1;
frame_read_monitor #(.FRAME_PIXELS(4),.SIGNATURE_CHECK(0)) disabled_monitor(
 .clk(clk),.rst(rst),.display_valid_async(valid),.display_slot_async(slot),.vs(vs),
 .fifo_read_req(req),.fifo_empty(empty),.fifo_valid(pixel),.fifo_data(data),
 .underflow_count(under0),.underflow_sticky(sticky0),.mismatch_count(wrong0),.mismatch_sticky(wrong_sticky0));
frame_read_monitor #(.FRAME_PIXELS(4),.SIGNATURE_CHECK(1)) enabled_monitor(
 .clk(clk),.rst(rst),.display_valid_async(valid),.display_slot_async(slot),.vs(vs),
 .fifo_read_req(req),.fifo_empty(empty),.fifo_valid(pixel),.fifo_data(data),
 .underflow_count(under1),.underflow_sticky(sticky1),.mismatch_count(wrong1),.mismatch_sticky(wrong_sticky1));
integer i;
initial begin
 repeat(3) @(negedge clk);rst=0;valid=1;
 repeat(5) @(negedge clk);
 for(i=0;i<256;i=i+1)begin
  @(negedge clk);vs=(i%8)==0;pixel=(i%4)!=0;data=i;slot=(i/16)%5;req=1;empty=(i%7)==0;
  @(posedge clk);#1;
  if(under0!==under1 || sticky0!==sticky1 || wrong0!==16'd0 || wrong_sticky0!==1'b0)begin
   $display("FAIL diagnostics switch");$stop;
  end
 end
 if(under0==0 || wrong1==0)begin $display("FAIL diagnostics coverage");$stop;end
 $display("PASS signature switch: signature disabled, FIFO underflow behavior preserved");$finish;
end
endmodule
