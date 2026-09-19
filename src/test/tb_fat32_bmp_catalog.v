`timescale 1ns/1ps

module tb_fat32_bmp_catalog;
reg clk=0, rst=1, init_done=0, direct_volume=0;
wire sd_read; wire [31:0] sd_addr;
reg sd_valid=0, sd_end=0; reg [7:0] sd_data=0;
wire candidate_valid, scan_done, volume_valid;
wire [31:0] first_cluster, file_size, fat_start, data_start;
wire [7:0] spc;
wire [2:0] catalog_candidate_count;
reg candidate_release=0;
reg [1:0] transport_state=0;
reg [31:0] transport_addr=0;
reg [9:0] transport_index=0;
integer seen_mbr_root, seen_mbr_fat, seen_direct_root;

always #5 clk=~clk;

fat32_bmp_catalog dut(
    .clk(clk),.rst(rst),.sd_init_done(init_done),.sd_sec_read(sd_read),.sd_sec_read_addr(sd_addr),
    .sd_sec_read_data_valid(sd_valid),.sd_sec_read_data(sd_data),.sd_sec_read_end(sd_end),
    .candidate_valid(candidate_valid),.candidate_first_cluster(first_cluster),.candidate_file_size(file_size),
    .fat_start_sector(fat_start),.first_data_sector(data_start),.sectors_per_cluster(spc),
    .candidate_count(catalog_candidate_count),
    .candidate_release(candidate_release),.stop(1'b0),.scan_done(scan_done),.volume_valid(volume_valid)
);

function [7:0] sector_byte;
    input [31:0] addr;
    input [9:0] index;
    begin
        sector_byte=8'd0;
        if (!direct_volume && addr==0) begin
            if(index==450) sector_byte=8'h0c;
            if(index==454) sector_byte=8'd100;
        end else if ((!direct_volume && addr==100) || (direct_volume && addr==0)) begin
            if(index==11) sector_byte=8'd0;
            if(index==12) sector_byte=8'd2;
            if(index==13) sector_byte=8'd1;
            if(index==14) sector_byte=8'd1;
            if(index==16) sector_byte=8'd1;
            if(index==36) sector_byte=8'd1;
            if(index==44) sector_byte=8'd2;
        end else if (!direct_volume && addr==101) begin
            if(index==8) sector_byte=8'd3;
        end else if ((!direct_volume && addr==102) || (direct_volume && addr==2)) begin
            // MBR 卷首项有效；直接卷将有效项放在扇区最后一项，验证
            // 数据末拍与扇区结束同拍时目录候选不会被遗漏。
            if((!direct_volume && index==0) || (direct_volume && index==480)) sector_byte="I";
            if((!direct_volume && index==8) || (direct_volume && index==488)) sector_byte="B";
            if((!direct_volume && index==9) || (direct_volume && index==489)) sector_byte="M";
            if((!direct_volume && index==10) || (direct_volume && index==490)) sector_byte="P";
            if((!direct_volume && index==26) || (direct_volume && index==506)) sector_byte=8'd5;
            if((!direct_volume && index==28) || (direct_volume && index==508)) sector_byte=8'd100;
            // MBR 卷用已删除目录项填满本簇，强制跟随根目录 FAT 链。
            if(!direct_volume && index>=32) begin
                if(index[4:0]==0) sector_byte=8'he5;
            end
            // 直接卷的最后一项才是 BMP；此前目录项不能用 0x00，
            // 否则 FAT32 会把它解释为目录结束标记。
            if(direct_volume && index<480 && index[4:0]==0) sector_byte=8'he5;
        end else if (!direct_volume && addr==103) begin
            // 根目录下一簇的第二张有效 BMP，后接目录结束标记。
            if(index==0) sector_byte="J";
            if(index==8) sector_byte="B";
            if(index==9) sector_byte="M";
            if(index==10) sector_byte="P";
            if(index==26) sector_byte=8'd7;
            if(index==28) sector_byte=8'd120;
            if(index==32) sector_byte=8'h00;
        end
    end
endfunction

always @(posedge clk) begin
    sd_valid<=0; sd_end<=0;
    if(rst) begin
        transport_state<=0; transport_addr<=0; transport_index<=0;
    end else case(transport_state)
        0: if(sd_read) begin transport_addr<=sd_addr; transport_index<=0; transport_state<=1; end
        1: begin
            sd_data<=sector_byte(transport_addr,transport_index); sd_valid<=1;
            if(transport_index==10'd511) transport_state<=2;
            else transport_index<=transport_index+1'b1;
        end
        // 真实仲裁器在每个扇区后插入 GAP；模型也留出一拍，保证下一
        // 个保持型请求的地址已稳定后再重新锁存。
        2: begin sd_end<=1; transport_state<=3; end
        3: transport_state<=0;
        default: transport_state<=0;
    endcase
    if(sd_read && sd_addr==102) seen_mbr_root<=1;
    if(sd_read && sd_addr==101) seen_mbr_fat<=1;
    if(direct_volume && sd_read && sd_addr==2) seen_direct_root<=1;
end

task release_candidate;
    begin
        @(negedge clk); candidate_release=1;
        @(negedge clk); candidate_release=0;
    end
endtask

initial begin
    seen_mbr_root=0; seen_mbr_fat=0; seen_direct_root=0;
    repeat(3) @(posedge clk); rst=0; init_done=1;
    wait(candidate_valid);
    if(first_cluster!=32'd5 || file_size!=32'd100) $fatal(1,"MBR first BMP descriptor incorrect");
    release_candidate;
    wait(candidate_valid);
    if(first_cluster!=32'd7 || file_size!=32'd120) $fatal(1,"root FAT-chain BMP descriptor incorrect");
    release_candidate;
    wait(scan_done);
    if(!volume_valid || !seen_mbr_root || !seen_mbr_fat) $fatal(1,"MBR root/FAT traversal incomplete");

    // 第二轮为 LBA0 直接 FAT32 卷。
    @(negedge clk); rst=1; init_done=0; direct_volume=1;
    repeat(3) @(posedge clk); rst=0; init_done=1;
    wait(candidate_valid);
    if(first_cluster!=32'd5 || fat_start!=32'd1 || data_start!=32'd2)
        $fatal(1,"direct FAT32 volume was not located");
    release_candidate;
    wait(scan_done);
    if(!seen_direct_root) $fatal(1,"direct FAT32 root directory was not read");
    $display("PASS FAT32 BMP catalog: MBR/direct volumes and root FAT chain");
    $finish;
end
endmodule
