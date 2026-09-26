`timescale 1ns/1ps
// 定向检查地址运算保持不变及 FIFO 水位边界。
module tb_wav_reader_resource_opt;
reg clk=0,rst=1,read_toggle=0;
wire [31:0] level;
integer n,j;
reg [31:0] expected;
always #5 clk=~clk;
fat32_wav_reader dut(
 .clk(clk),.rst(rst),.sd_init_done(1'b0),.enable(1'b0),
 .sd_data(8'd0),.sd_data_valid(1'b0),.sd_sec_read_end(1'b0),
 .fifo_full(1'b0),.audio_read_toggle(read_toggle),.audio_fifo_level(level),
 .sd_sec_read(),.sd_sec_read_addr(),.fifo_we(),.fifo_din(),
 .busy(),.done(),.file_found(),.format_ok(),.format_error()
);
task reset_reader;
begin
 @(negedge clk);rst=1;read_toggle=0;
 repeat(2) @(negedge clk);
 rst=0;
end
endtask
initial begin
 reset_reader;
 // 对所有合法簇大小测试首簇、普通簇及大簇号的 32 位截断结果。
 for(n=0;n<8;n=n+1)begin
  for(j=0;j<3;j=j+1)begin
   @(negedge clk);
   dut.state=4'd12;dut.spc=8'd1<<n;
   case(j)0:dut.cluster=32'd2;1:dut.cluster=32'd12345;2:dut.cluster=32'h0fff_fff0;endcase
   expected=(dut.cluster-32'd2)*(32'd1<<n);
   @(posedge clk);#1;
   if(dut.cluster_offset!==expected || dut.state!==4'd13)
    $fatal(1,"cluster offset mismatch spc=%0d",1<<n);
  end
 end
 reset_reader;
 @(negedge clk);dut.state=4'd9;
 // 在接收计数器入口注入写事件，避免用庞大的虚拟文件掩盖边界检查。
 for(n=1;n<=4096;n=n+1)begin
  @(negedge clk);dut.fifo_we=1'b1;
  @(posedge clk);#1;
  if(level!==n)$fatal(1,"FIFO count mismatch at %0d: %0d",n,level);
  if(dut.fifo_room!==(n<=3968))$fatal(1,"FIFO waterline mismatch at %0d",n);
 end
 for(n=4095;n>=0;n=n-1)begin
  @(negedge clk);read_toggle=~read_toggle;
  repeat(4) @(posedge clk);
  #1;if(level!==n)$fatal(1,"FIFO drain mismatch at %0d: %0d",n,level);
 end
 @(negedge clk);read_toggle=~read_toggle;
 repeat(4) @(posedge clk);
 #1;if(level!==32'd0)$fatal(1,"empty FIFO count underflow");
 // 同周期读写保持占用不变。
 @(negedge clk);dut.fifo_we=1'b1;
 @(posedge clk);#1;
 @(negedge clk);read_toggle=~read_toggle;
 repeat(2) @(posedge clk);
 @(negedge clk);dut.fifo_we=1'b1;
 @(posedge clk);#1;
 if(level!==32'd1)$fatal(1,"simultaneous read/write changed occupancy");
 $display("PASS WAV resource optimization: offsets, FIFO boundaries");
 $finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
