`timescale 1ns/1ps

// 验证同一根目录扇区中的五个 BMP 能按物理顺序逐一输出。
// 每次释放候选后目录器会从保存的目录偏移继续，而不会重复或漏项。
module tb_fat32_bmp_catalog_five;
reg clk=0, rst=1, sd_valid=0, sd_end=0, candidate_release=0;
reg [7:0] sd_data=0;
wire sd_read, candidate_valid, scan_done;
wire [31:0] sd_addr, first_cluster, file_size;
wire [2:0] catalog_candidate_count;
reg [1:0] transport_state=0;
reg [31:0] transport_addr=0;
reg [9:0] transport_index=0;
reg candidate_seen=0;
integer candidate_count=0;
integer entry_number;
integer entry_offset;

always #5 clk=~clk;

fat32_bmp_catalog dut(
    .clk(clk),.rst(rst),.sd_init_done(1'b1),
    .sd_sec_read(sd_read),.sd_sec_read_addr(sd_addr),
    .sd_sec_read_data_valid(sd_valid),.sd_sec_read_data(sd_data),.sd_sec_read_end(sd_end),
    .candidate_valid(candidate_valid),.candidate_first_cluster(first_cluster),
    .candidate_file_size(file_size),.fat_start_sector(),.first_data_sector(),
    .sectors_per_cluster(),.candidate_count(catalog_candidate_count),
    .candidate_release(candidate_release),.stop(1'b0),
    .scan_done(scan_done),.volume_valid(),.volume_root_cluster()
);

function [7:0] sector_byte;
    input [31:0] addr;
    input [9:0] index;
    integer item;
    integer field;
    begin
        sector_byte=8'd0;
        if(addr==0) begin
            // LBA0 直接 FAT32：保留区 1、单 FAT、FAT 长度 1、根簇 2。
            if(index==11) sector_byte=8'd0;
            if(index==12) sector_byte=8'd2;
            if(index==13) sector_byte=8'd1;
            if(index==14) sector_byte=8'd1;
            if(index==16) sector_byte=8'd1;
            if(index==36) sector_byte=8'd1;
            if(index==44) sector_byte=8'd2;
        end else if(addr==2) begin
            item=index>>5;
            field=index[4:0];
            if(item<5) begin
                if(field==0) sector_byte=8'h41+item;
                if(field==8) sector_byte="B";
                if(field==9) sector_byte="M";
                if(field==10) sector_byte="P";
                if(field==26) sector_byte=8'd5+item;
                if(field==28) sector_byte=8'd100+item;
            end
            // 第六个目录项以 0x00 标记目录结束。
            if(item==5 && field==0) sector_byte=8'h00;
        end
    end
endfunction

always @(posedge clk) begin
    sd_valid<=0;
    sd_end<=0;
    candidate_release<=0;
    if(rst) begin
        transport_state<=0;
        transport_addr<=0;
        transport_index<=0;
        candidate_seen<=0;
    end else begin
        case(transport_state)
            0: if(sd_read) begin
                transport_addr<=sd_addr;
                transport_index<=0;
                transport_state<=1;
            end
            1: begin
                sd_data<=sector_byte(transport_addr,transport_index);
                sd_valid<=1;
                if(transport_index==10'd511) transport_state<=2;
                else transport_index<=transport_index+1'b1;
            end
            2: begin sd_end<=1; transport_state<=3; end
            3: transport_state<=0;
            default: transport_state<=0;
        endcase

        if(candidate_valid && !candidate_seen) begin
            if(first_cluster != 32'd5+candidate_count || file_size != 32'd100+candidate_count)
                $fatal(1,"candidate %0d order/descriptor mismatch",candidate_count);
            candidate_count=candidate_count+1;
            candidate_release<=1;
            candidate_seen<=1;
        end else if(!candidate_valid) begin
            candidate_seen<=0;
        end
    end
end

initial begin
    repeat(3) @(posedge clk);
    rst=0;
    // 扫描结束与第一个缓存候选在同一拍发出；等待候选释放链完整走完。
    wait(candidate_count==5);
    wait(scan_done);
    if(candidate_count!=5) $fatal(1,"expected five BMP candidates, got %0d",candidate_count);
    if(catalog_candidate_count!=3'd5)
        $fatal(1,"catalogue diagnostic count mismatch: %0d",catalog_candidate_count);
    $display("PASS FAT32 BMP catalog: five root entries emitted in physical order");
    $finish;
end

initial begin
    #200000;
    $fatal(1,"five-candidate catalog timeout, count=%0d",candidate_count);
end
endmodule
