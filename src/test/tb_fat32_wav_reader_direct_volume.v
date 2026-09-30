`timescale 1ns/1ps

module tb_fat32_wav_reader_direct_volume;
reg clk=0,rst=1,valid=0,sec_end=0;
reg [7:0] data=0;
wire req; wire [31:0] addr;
integer i;
always #5 clk=~clk;

fat32_wav_reader dut(
 .clk(clk),.rst(rst),.sd_init_done(1'b1),.enable(1'b1),.sd_sec_read(req),.sd_sec_read_addr(addr),
 .sd_data(data),.sd_data_valid(valid),.sd_sec_read_end(sec_end),.fifo_we(),.fifo_din(),.fifo_full(1'b0),
 .audio_read_toggle(1'b0),.audio_fifo_level(),.busy(),.done(),.file_found(),.format_ok(),.format_error(),
 .volume_valid(1'b0),.volume_fat_start(32'd0),.volume_data_start(32'd0),
 .volume_root_cluster(32'd0),.volume_sectors_per_cluster(8'd0)
);

task send_boot_sector;
 begin
  wait(req && addr==0);
  for(i=0;i<512;i=i+1) begin
   @(negedge clk); valid=1; data=0;
   if(i==82) data="F"; if(i==83) data="A"; if(i==84) data="T";
   if(i==85) data="3"; if(i==86) data="2";
  end
  @(negedge clk); valid=0; sec_end=1;
  @(negedge clk); sec_end=0;
 end
endtask

initial begin
 repeat(3) @(posedge clk); rst=0;
 send_boot_sector;
 repeat(2) @(posedge clk);
 if(dut.state!=4'd2 || addr!=0) $fatal(1,"direct FAT32 boot sector did not remain at LBA0");
 $display("PASS WAV reader: direct FAT32 volume selects LBA0 BPB");
 $finish;
end
endmodule
