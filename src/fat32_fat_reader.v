// FAT32 table entry lookup. One 512-byte sector is streamed by the caller.
module fat32_fat_reader(
 input wire clk,input wire rst,input wire start,input wire [31:0] cluster,
 input wire [31:0] fat_start_sector,input wire [7:0] sectors_per_cluster,
 output reg request,output reg [31:0] request_sector,
 input wire byte_valid,input wire [8:0] byte_index,input wire [7:0] byte_data,
 input wire sector_done,output reg done,output reg [31:0] next_cluster,
 output reg end_of_chain
);
 reg busy; reg [8:0] off; reg [7:0] b0,b1,b2;
 always @(posedge clk or posedge rst) begin
  if(rst) begin busy<=0;request<=0;request_sector<=0;done<=0;next_cluster<=0;end_of_chain<=0;off<=0;b0<=0;b1<=0;b2<=0; end
  else begin
   request<=0; done<=0;
   if(start && !busy) begin busy<=1; off<=(cluster[6:0]<<2); request_sector<=fat_start_sector+(cluster>>7); request<=1; end
   else if(busy) begin
    if(byte_valid && byte_index==off) b0<=byte_data;
    if(byte_valid && byte_index==off+1) b1<=byte_data;
    if(byte_valid && byte_index==off+2) b2<=byte_data;
    if(byte_valid && byte_index==off+3) begin next_cluster<={byte_data,b2,b1,b0}&32'h0fffffff; end_of_chain<=({byte_data,b2,b1,b0}>=32'h0ffffff8); end
    if(sector_done) begin busy<=0;done<=1; end
   end
  end
 end
endmodule
