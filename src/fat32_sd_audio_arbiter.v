// Single-owner arbiter for FAT-table and file-data sector reads.
// Requests are level-held by the clients until the corresponding done pulse.
module fat32_sd_audio_arbiter(
 input wire clk,input wire rst,
 input wire fat_req,input wire [31:0] fat_addr,
 input wire data_req,input wire [31:0] data_addr,
 output reg sd_req,output reg [31:0] sd_addr,
 input wire sd_byte_valid,input wire [8:0] sd_byte_index,input wire [7:0] sd_byte,
 input wire sd_end,
 output wire fat_byte_valid,output wire [8:0] fat_byte_index,output wire [7:0] fat_byte,
 output wire fat_done,output wire data_byte_valid,output wire [8:0] data_byte_index,
 output wire [7:0] data_byte,output wire data_done,input wire fat_ack,input wire data_ack
);
 localparam IDLE=2'd0,FAT=2'd1,DATA=2'd2;
 reg [1:0] owner; reg [8:0] byte_count;
 assign fat_byte_valid=sd_byte_valid && owner==FAT;
 assign fat_byte_index=byte_count; assign fat_byte=sd_byte;
 assign data_byte_valid=sd_byte_valid && owner==DATA;
 assign data_byte_index=byte_count; assign data_byte=sd_byte;
 assign fat_done=(sd_end && owner==FAT); assign data_done=(sd_end && owner==DATA);
 always @(posedge clk or posedge rst) begin
  if(rst) begin owner<=IDLE;sd_req<=0;sd_addr<=0;byte_count<=0; end
  else begin
   case(owner)
    IDLE: begin
      sd_req<=0; byte_count<=0;
      if(fat_req) begin owner<=FAT;sd_addr<=fat_addr;sd_req<=1; end
      else if(data_req) begin owner<=DATA;sd_addr<=data_addr;sd_req<=1; end
    end
    FAT: begin
      if(sd_byte_valid) byte_count<=byte_count+1'b1;
      if(sd_end || fat_ack) begin sd_req<=0;owner<=IDLE; end
    end
    DATA: begin
      if(sd_byte_valid) byte_count<=byte_count+1'b1;
      if(sd_end || data_ack) begin sd_req<=0;owner<=IDLE; end
    end
    default: begin owner<=IDLE;sd_req<=0; end
   endcase
  end
 end
endmodule
