// FAT32 WAV data streamer (first playable path).
// The module consumes a contiguous cluster range beginning at start_cluster;
// FAT-chain advancement is supplied through next_cluster/next_valid.  It
// skips the canonical 44-byte WAV header and packs little-endian stereo
// 16-bit samples into {right[15:0],left[15:0]} FIFO words.
module fat32_wav_data_stream #(
  parameter [31:0] DATA_START_SECTOR = 0
) (
  input wire clk,input wire rst,input wire start,
  input wire [31:0] start_cluster,input wire [31:0] file_size,
  input wire [31:0] first_data_sector,input wire [7:0] sectors_per_cluster,
  output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,
  input wire [7:0] sd_data,input wire sd_data_valid,input wire sd_sec_read_end,
  input wire [31:0] next_cluster,input wire next_cluster_valid,
  output reg request_next_cluster,output reg fifo_we,output reg [31:0] fifo_din,
  input wire fifo_full,output reg busy,output reg done
);
  reg [31:0] cluster,sector_in_cluster,file_pos;
  reg [1:0] sample_byte; reg [7:0] b0,b1,b2;
  reg waiting_sector;
  always @(posedge clk or posedge rst) begin
    if(rst) begin
      sd_sec_read<=0;sd_sec_read_addr<=0;request_next_cluster<=0;
      fifo_we<=0;fifo_din<=0;busy<=0;done<=0;cluster<=0;sector_in_cluster<=0;
      file_pos<=0;sample_byte<=0;b0<=0;b1<=0;b2<=0;waiting_sector<=0;
    end else begin
      fifo_we<=0;done<=0;
      if (next_cluster_valid) request_next_cluster<=0;
      if(start && !busy) begin
        busy<=1; cluster<=start_cluster; sector_in_cluster<=0; file_pos<=0;
        sample_byte<=0; sd_sec_read_addr<=first_data_sector + ((start_cluster-2)*sectors_per_cluster);
        sd_sec_read<=1; waiting_sector<=1;
      end else if(busy) begin
        if(sd_data_valid && file_pos < file_size) begin
          file_pos<=file_pos+1;
          if(file_pos < 44) begin end
          else if(!fifo_full) begin
            case(sample_byte)
              0: b0<=sd_data;
              1: b1<=sd_data;
              2: b2<=sd_data;
              3: begin fifo_din<={sd_data,b2,b1,b0}; fifo_we<=1; end
            endcase
            sample_byte<=sample_byte+1'b1;
          end
        end
        if(sd_sec_read_end) begin
          sd_sec_read<=0; waiting_sector<=0;
          if(file_pos >= file_size) begin busy<=0;done<=1; end
          else if(sector_in_cluster + 1 < sectors_per_cluster) begin
            sector_in_cluster<=sector_in_cluster+1;
            sd_sec_read_addr<=sd_sec_read_addr+1; sd_sec_read<=1; waiting_sector<=1;
          end else begin
            request_next_cluster<=1; sector_in_cluster<=0;
          end
        end
        if(next_cluster_valid) begin
          cluster<=next_cluster;
          sd_sec_read_addr<=first_data_sector + ((next_cluster-2)*sectors_per_cluster);
          sd_sec_read<=1; waiting_sector<=1;
        end
      end
    end
  end
endmodule
