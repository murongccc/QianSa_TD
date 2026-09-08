// FAT32 audio file locator/reader front end.
// First implementation deliberately keeps the SD transaction interface
// identical to sd_card_top: assert sd_sec_read for one sector and consume
// byte_valid/data until sector_end.  It discovers WAN_CAN_GE.WAV by name.
// The data-stream state is left explicit so FAT-chain and WAV parsing can be
// added without changing the top-level SD wiring.
module fat32_audio_controller #(
    parameter [7:0] NAME0=8'h57, NAME1=8'h41, NAME2=8'h4E,
    parameter [7:0] NAME3=8'h5F, NAME4=8'h43, NAME5=8'h41,
    parameter [7:0] NAME6=8'h4E, NAME7=8'h5F,
    parameter [7:0] EXT0=8'h57, EXT1=8'h41, EXT2=8'h56
) (
    input wire clk, input wire rst, input wire sd_init_done,
    output reg sd_sec_read, output reg [31:0] sd_sec_read_addr,
    input wire [7:0] sd_sec_read_data, input wire sd_sec_read_data_valid,
    input wire sd_sec_read_end,
    output reg fifo_we, output reg [31:0] fifo_din, input wire fifo_full,
    output reg busy, output reg file_found, output reg done,
    output reg [31:0] file_start_cluster, output reg [31:0] file_size
    ,output reg [31:0] data_start_sector, output reg [7:0] data_sectors_per_cluster
);
    localparam ST_IDLE=0, ST_MBR=1, ST_BPB=2, ST_DIR=3, ST_FAT=4, ST_HOLD=5;
    reg [2:0] state;
    reg [8:0] pos;
    reg [31:0] part_lba, first_fat, first_data, root_cluster;
    reg [31:0] dir_sector;
    reg [7:0] spc, fats;
    reg [15:0] reserved;
    reg [31:0] spf;
    reg [31:0] current_cluster;
    reg [8:0] sector_byte_index;
    wire fat_done, fat_eoc;
    wire [31:0] fat_next_cluster;
    wire fat_request;
    wire [31:0] fat_request_sector;
    reg [7:0] ent [0:31];
    integer i;
    function [15:0] le16(input integer a); begin le16={ent[a+1],ent[a]}; end endfunction
    function [31:0] le32(input integer a); begin le32={ent[a+3],ent[a+2],ent[a+1],ent[a]}; end endfunction

    always @(posedge clk or posedge rst) begin
      if (rst) begin
        state<=ST_IDLE; pos<=0; sd_sec_read<=0; sd_sec_read_addr<=0;
        fifo_we<=0; fifo_din<=0; busy<=0; file_found<=0; done<=0;
        file_start_cluster<=0; file_size<=0; part_lba<=0; first_fat<=0;
        first_data<=0; root_cluster<=0; dir_sector<=0; spc<=0; fats<=0; spf<=0; reserved<=0; current_cluster<=0; sector_byte_index<=0; data_start_sector<=0; data_sectors_per_cluster<=0;
        for(i=0;i<32;i=i+1) ent[i]<=0;
      end else begin
        fifo_we<=0; done<=0;
        case(state)
          ST_IDLE: if(sd_init_done) begin
            busy<=1; file_found<=0; pos<=0; sd_sec_read_addr<=0;
            sd_sec_read<=1; state<=ST_MBR;
          end
          ST_MBR: begin
            if(sd_sec_read_data_valid) begin
              if(pos==9'd454) part_lba<=sd_sec_read_data;
              if(pos==9'd455) part_lba[15:8]<=sd_sec_read_data;
              if(pos==9'd456) part_lba[23:16]<=sd_sec_read_data;
              if(pos==9'd457) part_lba[31:24]<=sd_sec_read_data;
              pos<=pos+1'b1;
            end
            if(sd_sec_read_end) begin
              sd_sec_read<=0; pos<=0;
              // part_lba is assembled with nonblocking assignments while
              // the sector is being consumed; use the captured value here.
              sd_sec_read_addr<=part_lba;
              sd_sec_read<=1; state<=ST_BPB;
            end
          end
          ST_BPB: begin
            if(sd_sec_read_data_valid) begin
              if(pos==9'd13) spc<=sd_sec_read_data;
              if(pos==9'd14) reserved[7:0]<=sd_sec_read_data;
              if(pos==9'd15) reserved[15:8]<=sd_sec_read_data;
              if(pos==9'd16) fats<=sd_sec_read_data;
              if(pos>=9'd36 && pos<=9'd39) spf[(pos-36)*8 +: 8]<=sd_sec_read_data;
              if(pos>=9'd44 && pos<=9'd47) root_cluster[(pos-44)*8 +: 8]<=sd_sec_read_data;
              pos<=pos+1'b1;
            end
            if(sd_sec_read_end) begin
              sd_sec_read<=0; pos<=0;
              first_fat<=part_lba + reserved;
              first_data<=part_lba + reserved + (fats*spf);
              data_start_sector<=part_lba + reserved + (fats*spf);
              data_sectors_per_cluster<=spc;
              dir_sector<=part_lba + reserved + (fats*spf) + ((root_cluster-32'd2) * spc);
              sd_sec_read_addr<=part_lba + reserved + (fats*spf) + ((root_cluster-32'd2) * spc);
              sector_byte_index<=0; sd_sec_read<=1; state<=ST_DIR;
            end
          end
          ST_DIR: begin
            if(sd_sec_read_data_valid) begin ent[pos[4:0]]<=sd_sec_read_data; pos<=pos+1'b1; sector_byte_index<=sector_byte_index+1'b1; end
            if(pos[4:0]==5'd31 && sd_sec_read_data_valid) begin
              if(ent[0]==NAME0 && ent[1]==NAME1 && ent[2]==NAME2 && ent[3]==NAME3 &&
                 ent[4]==NAME4 && ent[5]==NAME5 && ent[6]==NAME6 && ent[7]==NAME7 &&
                 ent[8]==EXT0 && ent[9]==EXT1 && ent[10]==EXT2 && ent[11]!=8'h0F) begin
                file_found<=1; file_start_cluster<={ent[21],ent[20],ent[27],ent[26]}; current_cluster<={ent[21],ent[20],ent[27],ent[26]};
                file_size<={sd_sec_read_data,ent[30],ent[29],ent[28]};
                sd_sec_read<=0; state<=ST_FAT;
              end else if(ent[0]==8'h00) begin busy<=0; done<=1; sd_sec_read<=0; state<=ST_HOLD; end
            end
            if(sd_sec_read_end && !file_found && ent[0]!=8'h00) begin
              // First directory cluster only for this stage; FAT-chain
              // traversal is added in the next controller revision.
              sd_sec_read<=0; busy<=0; done<=1; state<=ST_HOLD;
            end
          end
          ST_FAT: begin
            if (fat_request) begin
              sd_sec_read_addr<=fat_request_sector;
              sd_sec_read<=1'b1;
            end
            if (fat_done) begin
              sd_sec_read<=0;
              busy<=0; done<=1; state<=ST_HOLD;
            end
          end
          ST_HOLD: begin end
          default: state<=ST_IDLE;
        endcase
      end
    end
    fat32_fat_reader u_fat_reader(
      .clk(clk),.rst(rst),.start(state==ST_FAT && !sd_sec_read),.cluster(current_cluster),
      .fat_start_sector(first_fat),.sectors_per_cluster(spc),.request(fat_request),
      .request_sector(fat_request_sector),.byte_valid(sd_sec_read_data_valid),
      .byte_index(sector_byte_index),.byte_data(sd_sec_read_data),
      .sector_done(sd_sec_read_end),.done(fat_done),.next_cluster(fat_next_cluster),.end_of_chain(fat_eoc));
endmodule
