// FAT32 BPB parser. Feed one 512-byte sector sequentially after start.
// The parser accepts a FAT32 boot sector and exposes the fields required by
// directory/FAT readers. It does not access the SD card itself.
module fat32_boot_parser (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] partition_base_sector,
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,
    output reg         busy,
    output reg         done,
    output reg         valid,
    output reg [15:0]  bytes_per_sector,
    output reg [7:0]   sectors_per_cluster,
    output reg [15:0]  reserved_sector_count,
    output reg [7:0]   fat_count,
    output reg [31:0]  sectors_per_fat,
    output reg [31:0]  root_cluster,
    output reg [31:0]  total_sectors,
    output reg [31:0]  partition_start_sector,
    output reg [31:0]  first_fat_sector,
    output reg [31:0]  first_data_sector
);
    reg [9:0] pos;
    reg [7:0] sig0;
    reg [7:0] mem [0:63];
    integer i;

    function [15:0] le16;
        input integer a;
        begin le16 = {mem[a+1],mem[a]}; end
    endfunction
    function [31:0] le32;
        input integer a;
        begin le32 = {mem[a+3],mem[a+2],mem[a+1],mem[a]}; end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy<=0; done<=0; valid<=0; pos<=0; sig0<=0;
            bytes_per_sector<=0; sectors_per_cluster<=0; reserved_sector_count<=0;
            fat_count<=0; sectors_per_fat<=0; root_cluster<=0; total_sectors<=0;
            partition_start_sector<=0; first_fat_sector<=0; first_data_sector<=0;
            for (i=0;i<64;i=i+1) mem[i]<=0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1; valid <= 1'b0; pos <= 0; sig0<=0;
            end else if (busy && byte_valid) begin
                if (pos < 64) mem[pos] <= byte_data;
                if (pos == 10'd510) sig0 <= byte_data;
                if (pos == 10'd511) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    // FAT32 BPB signature and FAT32-specific fields.
                    valid <= (mem[54]=="F" && mem[55]=="A" && mem[56]=="T" &&
                              mem[57]=="3" && mem[58]=="2" &&
                              sig0==8'h55 && byte_data==8'hAA &&
                              le16(11)==16'd512 && le32(44)!=0);
                    bytes_per_sector <= le16(11);
                    sectors_per_cluster <= mem[13];
                    reserved_sector_count <= le16(14);
                    fat_count <= mem[16];
                    sectors_per_fat <= le32(36);
                    root_cluster <= le32(44);
                    total_sectors <= (le16(19)!=0) ? le16(19) : le32(32);
                    partition_start_sector <= partition_base_sector;
                    first_fat_sector <= partition_base_sector + le16(14);
                    first_data_sector <= partition_base_sector + le16(14) + (mem[16] * le32(36));
                end
                pos <= pos + 1'b1;
            end
        end
    end
endmodule
