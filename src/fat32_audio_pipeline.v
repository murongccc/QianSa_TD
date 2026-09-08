// Unified FAT32 filename -> WAV PCM FIFO pipeline.
module fat32_audio_pipeline(
 input wire clk,input wire rst,input wire sd_init_done,
 output wire sd_sec_read,output wire [31:0] sd_sec_read_addr,
 input wire [7:0] sd_data,input wire sd_data_valid,input wire sd_sec_read_end,
 output wire fifo_we,output wire [31:0] fifo_din,input wire fifo_full,
 output wire busy,output wire done,output wire file_found
);
 wire loc_read; wire [31:0] loc_addr;
 wire loc_fifo_we; wire [31:0] loc_fifo_din;
 wire loc_busy,loc_done,loc_found;
 wire [31:0] start_cluster,file_size,data_start_sector;
 wire [7:0] data_spc;
 wire stream_read; wire [31:0] stream_addr;
 wire stream_fifo_we; wire [31:0] stream_fifo_din;
 wire stream_busy,stream_done,stream_req_next;
 wire arb_sd_req; wire [31:0] arb_sd_addr;
 wire arb_fat_valid, arb_data_valid, arb_fat_done, arb_data_done;
 wire [8:0] arb_fat_index, arb_data_index; wire [7:0] arb_fat_byte, arb_data_byte;
 reg stream_start, next_valid; reg [31:0] next_cluster;
 fat32_audio_controller u_loc(.clk(clk),.rst(rst),.sd_init_done(sd_init_done),
  .sd_sec_read(loc_read),.sd_sec_read_addr(loc_addr),.sd_sec_read_data(sd_data),
  .sd_sec_read_data_valid(arb_fat_valid),.sd_sec_read_end(arb_fat_done),
  .fifo_we(loc_fifo_we),.fifo_din(loc_fifo_din),.fifo_full(fifo_full),.busy(loc_busy),
  .file_found(loc_found),.done(loc_done),.file_start_cluster(start_cluster),.file_size(file_size),
  .data_start_sector(data_start_sector),.data_sectors_per_cluster(data_spc));
 fat32_wav_data_stream u_stream(.clk(clk),.rst(rst),.start(stream_start),
  .start_cluster(start_cluster),.file_size(file_size),.first_data_sector(data_start_sector),
  .sectors_per_cluster(data_spc),.sd_sec_read(stream_read),.sd_sec_read_addr(stream_addr),
  .sd_data(arb_data_byte),.sd_data_valid(arb_data_valid),.sd_sec_read_end(arb_data_done),
  .next_cluster(next_cluster),.next_cluster_valid(next_valid),.request_next_cluster(stream_req_next),
  .fifo_we(stream_fifo_we),.fifo_din(stream_fifo_din),.fifo_full(fifo_full),.busy(stream_busy),.done(stream_done));
 // The locator owns the initial MBR/BPB/directory transaction. Once it has
 // found the file, the data stream is routed through the single-owner arbiter.
 fat32_sd_audio_arbiter u_arbiter(
  .clk(clk),.rst(rst),
  .fat_req(loc_read && !loc_found),.fat_addr(loc_addr),
  .data_req(stream_read),.data_addr(stream_addr),
  .sd_req(arb_sd_req),.sd_addr(arb_sd_addr),
  .sd_byte_valid(sd_data_valid),.sd_byte_index(9'd0),.sd_byte(sd_data),.sd_end(sd_sec_read_end),
  .fat_byte_valid(arb_fat_valid),.fat_byte_index(arb_fat_index),.fat_byte(arb_fat_byte),.fat_done(arb_fat_done),
  .data_byte_valid(arb_data_valid),.data_byte_index(arb_data_index),.data_byte(arb_data_byte),.data_done(arb_data_done),
  .fat_ack(1'b0),.data_ack(1'b0));
 assign sd_sec_read = arb_sd_req;
 assign sd_sec_read_addr = arb_sd_addr;
 assign fifo_we = stream_fifo_we; assign fifo_din=stream_fifo_din;
 assign busy=loc_busy|stream_busy; assign done=stream_done; assign file_found=loc_found;
 always @(posedge clk or posedge rst) begin
  if(rst) begin stream_start<=0; next_valid<=0; next_cluster<=0; end
  else begin
   stream_start<=0; next_valid<=0;
   if(loc_done && loc_found) stream_start<=1;
   // FAT lookup is connected in the next refinement; keep handshake benign
   // until the shared SD arbiter is enabled.
  end
 end
endmodule
