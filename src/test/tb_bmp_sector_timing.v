`timescale 1ns/1ps

module tb_bmp_sector_timing;
parameter integer SPC=1;
parameter integer FAT_EDGE=1;
localparam [31:0] FIRST_CLUSTER=FAT_EDGE ? 32'd127 : 32'd5;
localparam [31:0] FIRST_SECTOR=32'd1000+(FIRST_CLUSTER-32'd2)*SPC;
localparam [31:0] NEXT_CLUSTER=FAT_EDGE ? 32'h01000007 : 32'd7;
localparam [31:0] NEXT_SECTOR=32'd1000+(NEXT_CLUSTER-32'd2)*SPC;
localparam [31:0] PIXEL_OFFSET=SPC*512+54;
localparam [31:0] FILE_LENGTH=PIXEL_OFFSET+4;
localparam [7:0] CLUSTER_SIZE=SPC;
// 连续扇区直到簇尾，FAT 末字节与 done 同拍后进入碎片下一簇。
reg clk=0,rst=1,load_start=0,write_req_ack=0,sd_valid=0,sd_end=0;
reg [7:0] sd_data=0;
wire ready,write_req,sd_read,load_failed;
wire [31:0] sd_addr;
wire pixel_valid,frame_last;
wire [23:0] pixel_data;
reg [1:0] transport_state=0;
reg [31:0] transport_addr=0;
reg [9:0] transport_index=0;
integer saw_fat,saw_second_cluster,requests,pixels;
reg [31:0] expected_addr;

always #5 clk=~clk;

bmp_read dut(
    .clk(clk),.rst(rst),.ready(ready),.scan_start(1'b0),.scan_start_sector(0),.scan_max_sector(0),
    .scan_target_count(3'd0),.scan_done(),.scan_found_valid(),.scan_found_sector(),.scan_found_total(),
    .load_start(load_start),.load_sector(0),.sd_init_done(1'b1),.state_code(),.bmp_width(16'd0),.bmp_height(16'd0),
    .parsed_width(),.parsed_height(),.parsed_top_down(),.write_req(write_req),.write_req_ack(write_req_ack),
    .sd_sec_read(sd_read),.sd_sec_read_addr(sd_addr),.sd_sec_read_data(sd_data),.sd_sec_read_data_valid(sd_valid),
    .sd_sec_read_end(sd_end),.pixel_valid(pixel_valid),.pixel_ready(1'b1),.pixel_data(pixel_data),.pixel_last(),
    .frame_last(frame_last),.sector_ready(1'b1),.load_failed(load_failed),.bmp_data_wr_en(),.bmp_data(),
    // 目录长度与图头一致；大偏移迫使读取完整首簇后跳转碎片簇。
    .load_file_mode(1'b1),.load_first_cluster(FIRST_CLUSTER),.load_file_size(FILE_LENGTH),
    .fat_start_sector(32'd1000),.first_data_sector(32'd1000),.sectors_per_cluster(CLUSTER_SIZE)
);

function [7:0] sector_byte;
    input [31:0] addr;
    input [9:0] index;
    begin
        sector_byte=0;
        // 首簇第一个扇区保存图头，像素偏移位于下一簇。
        if(addr==FIRST_SECTOR) begin
            if(index==0) sector_byte="B"; if(index==1) sector_byte="M";
            if(index>=2 && index<=5)sector_byte=FILE_LENGTH>>((index-2)*8);
            if(index>=10 && index<=13)sector_byte=PIXEL_OFFSET>>((index-10)*8);
            if(index==14) sector_byte=8'd40;
            if(index==18 || index==22 || index==26) sector_byte=8'd1;
            if(index==28) sector_byte=8'd24;
        end else if(addr==32'd1000) begin
            // FAT_EDGE=1 时首簇 127 的项位于偏移 508～511。
            if(index[8:2]==FIRST_CLUSTER[6:0])sector_byte=NEXT_CLUSTER>>(index[1:0]*8);
        end else if(addr==NEXT_SECTOR && index>=54 && index<=56)begin
            case(index)54:sector_byte=8'h33;55:sector_byte=8'h22;56:sector_byte=8'h11;endcase
        end
    end
endfunction

always @(posedge clk) begin
    sd_valid<=0; sd_end<=0;
    if(rst) begin transport_state<=0; transport_addr<=0; transport_index<=0; end
    else case(transport_state)
        0: if(sd_read) begin
            if(requests==0 || requests==1)expected_addr=FIRST_SECTOR;
            else if(requests<=SPC)expected_addr=FIRST_SECTOR+requests-1;
            else if(requests==SPC+1)expected_addr=32'd1000;
            else if(requests==SPC+2)expected_addr=NEXT_SECTOR;
            else $fatal(1,"unexpected request count %0d",requests);
            if(sd_addr!==expected_addr)$fatal(1,"spc=%0d request=%0d addr=%h expected=%h",SPC,requests,sd_addr,expected_addr);
            requests=requests+1;
            transport_addr<=sd_addr;transport_index<=0;transport_state<=1;
        end
        1: begin
            sd_data<=sector_byte(transport_addr,transport_index); sd_valid<=1;
            if(transport_index==10'd511)begin
                if(FAT_EDGE)begin sd_end<=1;transport_state<=3;end
                else transport_state<=2;
            end
            else transport_index<=transport_index+1'b1;
        end
        2: begin sd_end<=1; transport_state<=3; end
        3: transport_state<=0;
        default: transport_state<=0;
    endcase
    if(pixel_valid)begin
        pixels=pixels+1;
        if(pixel_data!==24'h112233)$fatal(1,"pixel mismatch %h",pixel_data);
    end
    if(transport_state==1 && sd_addr!==transport_addr)$fatal(1,"request address changed while sector active");
    if(sd_read && sd_addr==32'd1000) saw_fat=1;
    if(sd_read && sd_addr==NEXT_SECTOR) saw_second_cluster=1;
end

initial begin
    saw_fat=0;saw_second_cluster=0;requests=0;pixels=0;
    repeat(3) @(posedge clk); rst=0;
    @(negedge clk); load_start=1;
    @(negedge clk); load_start=0;
    wait(write_req);
    @(negedge clk); write_req_ack=1;
    @(negedge clk); write_req_ack=0;
    wait(saw_second_cluster);
    wait(ready);
    if(!saw_fat || !saw_second_cluster || load_failed || requests!=SPC+3 || pixels!=1)
        $fatal(1,"fragmented BMP failed: fat=%b next=%b load_failed=%b",saw_fat,saw_second_cluster,load_failed);
    $display("PASS BMP sector timing SPC=%0d FAT_EDGE=%0d requests=%0d pixel=%0d",SPC,FAT_EDGE,requests,pixels);
    $finish;
end
initial begin #2000000;$fatal(1,"sector timing timeout");end
endmodule
