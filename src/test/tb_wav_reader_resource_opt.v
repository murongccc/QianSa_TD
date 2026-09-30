`timescale 1ns/1ps
// 定向检查地址运算保持不变及 FIFO 水位边界。
module tb_wav_reader_resource_opt;
reg clk=0,rst=1,read_toggle=0;
wire [31:0] level;
integer n,j;
reg [31:0] expected, cluster_delta, cluster_size;
always #5 clk=~clk;
fat32_wav_reader dut(
 .clk(clk),.rst(rst),.sd_init_done(1'b0),.enable(1'b0),
 .sd_data(8'd0),.sd_data_valid(1'b0),.sd_sec_read_end(1'b0),
 .fifo_full(1'b0),.audio_read_toggle(read_toggle),.audio_fifo_level(level),
 .sd_sec_read(),.sd_sec_read_addr(),.fifo_we(),.fifo_din(),
 .busy(),.done(),.file_found(),.format_ok(),.format_error(),
 .volume_valid(1'b0),.volume_fat_start(32'd0),.volume_data_start(32'd0),
 .volume_root_cluster(32'd0),.volume_sectors_per_cluster(8'd0)
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
 // 全部 8 位簇大小（含非法值）及边界簇号均保留旧乘法的 32 位截断结果。
 for(n=0;n<256;n=n+1)begin
  for(j=0;j<6;j=j+1)begin
   @(negedge clk);
   dut.state=4'd12;dut.spc=n[7:0];
   case(j)
    0:dut.cluster=32'd2;1:dut.cluster=32'd12345;2:dut.cluster=32'h0fff_fff0;
    3:dut.cluster=32'd0;4:dut.cluster=32'd1;5:dut.cluster=32'hffff_ffff;
   endcase
   cluster_delta=dut.cluster-32'd2;
   cluster_size=n;
   expected=cluster_delta*cluster_size;
   @(posedge clk);#1;
   // 新地址运算在 SD 请求空档用八拍移位加法完成。
   while(dut.state==4'd15)begin @(posedge clk);#1;end
   if(dut.cluster_offset!==expected || dut.state!==4'd13)
    $fatal(1,"cluster offset mismatch spc=%0d delta=%h",n,cluster_delta);
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
