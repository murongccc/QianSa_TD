`timescale 1ns/1ps

// 经真实图头和扇区握手验证最大尺寸、行填充、方向及非法尺寸拒绝。
module tb_bmp_read_resource_opt;
reg clk=0, rst=1, load_start=0, write_req_ack=0;
reg sd_valid=0, sd_end=0;
reg [7:0] sd_data=0;
wire ready, write_req, sd_read, load_failed;
wire pixel_valid, pixel_last, frame_last, parsed_top_down;
wire [23:0] pixel_data;
wire [15:0] parsed_width, parsed_height;
integer case_width, case_height, case_stride, seen_pixels;
integer expected_col, expected_row;
reg [31:0] height_bits, case_size;
reg check_pixels=0;
reg [23:0] expected_pixel;

always #5 clk=~clk;
bmp_read dut(
    .clk(clk),.rst(rst),.ready(ready),
    .scan_start(1'b0),.scan_start_sector(32'd0),.scan_max_sector(32'd0),
    .scan_target_count(3'd0),.scan_done(),.scan_found_valid(),
    .scan_found_sector(),.scan_found_total(),
    .load_start(load_start),.load_sector(32'd100),.sd_init_done(1'b1),
    .state_code(),.bmp_width(16'd0),.bmp_height(16'd0),
    .parsed_width(parsed_width),.parsed_height(parsed_height),
    .parsed_top_down(parsed_top_down),.write_req(write_req),.write_req_ack(write_req_ack),
    .sd_sec_read(sd_read),.sd_sec_read_addr(),.sd_sec_read_data(sd_data),
    .sd_sec_read_data_valid(sd_valid),.sd_sec_read_end(sd_end),
    .pixel_valid(pixel_valid),.pixel_ready(1'b1),.pixel_data(pixel_data),
    .pixel_last(pixel_last),.frame_last(frame_last),.sector_ready(1'b1),
    .load_failed(load_failed),.bmp_data_wr_en(),.bmp_data(),
    .load_file_mode(1'b0),.load_first_cluster(32'd0),.load_file_size(32'd0),
    .fat_start_sector(32'd0),.first_data_sector(32'd0),.sectors_per_cluster(8'd0)
);

function [7:0] image_byte;
    input integer offset;
    integer payload, row_index, row_byte, col_index;
    begin
        image_byte=8'd0;
        case(offset)
            0: image_byte="B";
            1: image_byte="M";
            2,3,4,5: image_byte=case_size >> ((offset-2)*8);
            10: image_byte=8'd54;
            14: image_byte=8'd40;
            18,19,20,21: image_byte=case_width >> ((offset-18)*8);
            22,23,24,25: image_byte=height_bits >> ((offset-22)*8);
            26: image_byte=8'd1;
            28: image_byte=8'd24;
            default: if(offset>=54 && offset<case_size) begin
                payload=offset-54;
                row_index=payload/case_stride;
                row_byte=payload%case_stride;
                col_index=row_byte/3;
                if(row_byte>=case_width*3) image_byte=8'hee;
                else case(row_byte%3)
                    0: image_byte=col_index;
                    1: image_byte=row_index;
                    2: image_byte=col_index+row_index;
                endcase
            end
        endcase
    end
endfunction

always @(posedge clk) begin
    if(check_pixels && pixel_valid) begin
        expected_col=seen_pixels%case_width;
        expected_row=seen_pixels/case_width;
        expected_pixel[23:16]=expected_col+expected_row;
        expected_pixel[15:8]=expected_row;
        expected_pixel[7:0]=expected_col;
        if(pixel_data !== expected_pixel)
            $fatal(1,"pixel mismatch at %0d: %h",seen_pixels,pixel_data);
        if(pixel_last !== (expected_col==case_width-1) ||
           frame_last !== (seen_pixels==case_width*case_height-1))
            $fatal(1,"pixel/frame boundary mismatch at %0d",seen_pixels);
        seen_pixels=seen_pixels+1;
    end
end

task send_sector;
    input integer base_offset;
    integer byte_index;
    begin
        wait(sd_read);
        for(byte_index=0;byte_index<512;byte_index=byte_index+1) begin
            @(negedge clk);
            sd_valid=1;
            sd_data=image_byte(base_offset+byte_index);
        end
        @(negedge clk); sd_valid=0; sd_end=1;
        @(negedge clk); sd_end=0;
    end
endtask

task run_case;
    input integer width_value, height_value;
    input expected_valid;
    integer sector_index, sector_total;
    begin
        @(negedge clk); rst=1; check_pixels=0;
        case_width=width_value;
        height_bits=height_value;
        case_height=(height_value<0)?-height_value:height_value;
        case_stride=(width_value*3+3)&32'hffff_fffc;
        case_size=expected_valid ? 54+case_stride*case_height : 64;
        seen_pixels=0;
        repeat(3) @(negedge clk);
        rst=0; load_start=1;
        @(negedge clk); load_start=0;
        send_sector(0);
        if(!expected_valid) begin
            if(!ready || !load_failed || write_req)
                $fatal(1,"invalid size accepted: %0d x %0d",width_value,height_value);
        end else begin
            if(!write_req || parsed_width!=case_width || parsed_height!=case_height ||
               parsed_top_down!=(height_value<0))
                $fatal(1,"valid header failed: %0d x %0d",width_value,height_value);
            @(negedge clk); write_req_ack=1; check_pixels=1;
            @(negedge clk); write_req_ack=0;
            if(dut.row_stride!=case_stride)
                $fatal(1,"stride mismatch");
            sector_total=(case_size+511)/512;
            for(sector_index=0;sector_index<sector_total;sector_index=sector_index+1)
                send_sector(sector_index*512);
            repeat(3) @(negedge clk);
            if(!ready || load_failed || seen_pixels!=case_width*case_height)
                $fatal(1,"frame failed: %0d x %0d pixels=%0d",width_value,height_value,seen_pixels);
        end
        $display("PASS size %0d x %0d valid=%b",width_value,height_value,expected_valid);
    end
endtask

task run_truncated_case;
    begin
        @(negedge clk); rst=1; check_pixels=0;
        case_width=2; case_height=3; height_bits=32'd3;
        case_stride=8; case_size=32'd74; seen_pixels=0;
        repeat(3) @(negedge clk);
        rst=0; load_start=1;
        @(negedge clk); load_start=0;
        send_sector(0);
        if(!write_req) $fatal(1,"truncated header was not accepted for payload check");
        @(negedge clk); write_req_ack=1; check_pixels=1;
        @(negedge clk); write_req_ack=0;
        send_sector(0);
        repeat(3) @(negedge clk);
        if(!ready || !load_failed || seen_pixels!=5)
            $fatal(1,"truncated payload did not fail correctly");
        $display("PASS truncated payload rejected after 5 of 6 pixels");
    end
endtask

initial begin
    run_case(1920,1080,1'b1);
    run_case(1919,2,1'b1);
    run_case(1,-1080,1'b1);
    run_case(2,3,1'b1);
    run_case(3,3,1'b1);
    run_case(4,3,1'b1);
    run_case(1921,1,1'b0);
    run_case(1,1081,1'b0);
    run_case(1,-1081,1'b0);
    run_case(32'h0001_0780,1,1'b0);
    run_case(1,32'h0001_0438,1'b0);
    run_case(0,1,1'b0);
    run_case(1,0,1'b0);
    run_truncated_case;
    $display("PASS BMP resource optimization boundaries");
    $finish;
end
initial begin
    #100000000;
    $fatal(1,"timeout");
end
endmodule
