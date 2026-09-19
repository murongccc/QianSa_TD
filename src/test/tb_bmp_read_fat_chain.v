`timescale 1ns/1ps

module tb_bmp_read_fat_chain;
reg clk=0,rst=1,load_start=0,write_req_ack=0,sd_valid=0,sd_end=0;
reg [7:0] sd_data=0;
wire ready,write_req,sd_read,load_failed;
wire [31:0] sd_addr;
wire pixel_valid,frame_last;
reg [1:0] transport_state=0;
reg [31:0] transport_addr=0;
reg [9:0] transport_index=0;
integer saw_fat,saw_second_cluster;

always #5 clk=~clk;

bmp_read dut(
    .clk(clk),.rst(rst),.ready(ready),.scan_start(1'b0),.scan_start_sector(0),.scan_max_sector(0),
    .scan_target_count(3'd0),.scan_done(),.scan_found_valid(),.scan_found_sector(),.scan_found_total(),
    .load_start(load_start),.load_sector(0),.sd_init_done(1'b1),.state_code(),.bmp_width(16'd0),.bmp_height(16'd0),
    .parsed_width(),.parsed_height(),.parsed_top_down(),.write_req(write_req),.write_req_ack(write_req_ack),
    .sd_sec_read(sd_read),.sd_sec_read_addr(sd_addr),.sd_sec_read_data(sd_data),.sd_sec_read_data_valid(sd_valid),
    .sd_sec_read_end(sd_end),.pixel_valid(pixel_valid),.pixel_ready(1'b1),.pixel_data(),.pixel_last(),
    .frame_last(frame_last),.sector_ready(1'b1),.load_failed(load_failed),.bmp_data_wr_en(),.bmp_data(),
    .load_file_mode(1'b1),.load_first_cluster(32'd5),.load_file_size(32'd654),
    .fat_start_sector(32'd1000),.first_data_sector(32'd1000),.sectors_per_cluster(8'd1)
);

function [7:0] sector_byte;
    input [31:0] addr;
    input [9:0] index;
    begin
        sector_byte=0;
        // cluster 5 data sector: 1000 + (5 - 2) = 1003.
        if(addr==32'd1003) begin
            if(index==0) sector_byte="B"; if(index==1) sector_byte="M";
            if(index==2) sector_byte=8'h8e; if(index==3) sector_byte=8'd2; // 654 bytes
            if(index==10) sector_byte=8'd54;
            if(index==14) sector_byte=8'd40;
            if(index==18) sector_byte=8'd200;
            if(index==22) sector_byte=8'd1;
            if(index==26) sector_byte=8'd1;
            if(index==28) sector_byte=8'd24;
        end else if(addr==32'd1000) begin
            // FAT[5] 位于偏移 20，下一簇为 7。
            if(index==20) sector_byte=8'd7;
        end
    end
endfunction

always @(posedge clk) begin
    sd_valid<=0; sd_end<=0;
    if(rst) begin transport_state<=0; transport_addr<=0; transport_index<=0; end
    else case(transport_state)
        0: if(sd_read) begin transport_addr<=sd_addr; transport_index<=0; transport_state<=1; end
        1: begin
            sd_data<=sector_byte(transport_addr,transport_index); sd_valid<=1;
            if(transport_index==10'd511) transport_state<=2;
            else transport_index<=transport_index+1'b1;
        end
        2: begin sd_end<=1; transport_state<=3; end
        3: transport_state<=0;
        default: transport_state<=0;
    endcase
    if(sd_read && sd_addr==32'd1000) saw_fat=1;
    if(sd_read && sd_addr==32'd1005) saw_second_cluster=1;
end

initial begin
    saw_fat=0; saw_second_cluster=0;
    repeat(3) @(posedge clk); rst=0;
    @(negedge clk); load_start=1;
    @(negedge clk); load_start=0;
    wait(write_req);
    @(negedge clk); write_req_ack=1;
    @(negedge clk); write_req_ack=0;
    wait(saw_second_cluster);
    wait(ready);
    if(!saw_fat || !saw_second_cluster || load_failed)
        $fatal(1,"fragmented BMP failed: fat=%b next=%b load_failed=%b",saw_fat,saw_second_cluster,load_failed);
    $display("PASS BMP reader: fragmented FAT32 file crosses cluster 5 to 7");
    $finish;
end
endmodule
