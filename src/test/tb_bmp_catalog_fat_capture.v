`timescale 1ns/1ps

// 单独覆盖 FAT 四字节采集：扇区首尾偏移、字节间空拍和高四位屏蔽。
module tb_bmp_catalog_fat_capture;
reg clk=0, rst=1, sd_valid=0, sd_end=0;
reg [7:0] sd_data=0;
always #5 clk=~clk;
fat32_bmp_catalog dut(
    .clk(clk),.rst(rst),.sd_init_done(1'b1),.sd_sec_read(),.sd_sec_read_addr(),
    .sd_sec_read_data_valid(sd_valid),.sd_sec_read_data(sd_data),.sd_sec_read_end(sd_end),
    .candidate_valid(),.candidate_first_cluster(),.candidate_file_size(),
    .fat_start_sector(),.first_data_sector(),.sectors_per_cluster(),.candidate_count(),
    .candidate_release(1'b0),.stop(1'b0),.scan_done(),.volume_valid(),.volume_root_cluster()
);

task check_entry;
    input [8:0] byte_offset;
    input [31:0] entry_word;
    integer byte_index;
    reg [31:0] expected_cluster;
    begin
        @(negedge clk); rst=1; sd_valid=0; sd_end=0;
        repeat(2) @(negedge clk);
        rst=0;
        // 从 FAT 采集状态开始；卷扫描和候选握手由既有集成回归覆盖。
        dut.state=4'd6; dut.pos=10'd0; dut.fat_offset=byte_offset;
        for(byte_index=0;byte_index<512;byte_index=byte_index+1) begin
            sd_valid=1;
            if(byte_index>=byte_offset && byte_index<byte_offset+4)
                sd_data=entry_word >> ((byte_index-byte_offset)*8);
            else sd_data=8'ha5;
            @(negedge clk);
            sd_valid=0;
            repeat(2) @(negedge clk);
        end
        sd_end=1;
        @(negedge clk); sd_end=0;
        expected_cluster=entry_word & 32'h0fff_ffff;
        if(dut.fat_next_cluster_reg !== expected_cluster)
            $fatal(1,"FAT little-endian capture mismatch at offset %0d",byte_offset);
        @(negedge clk);
        if(expected_cluster>=32'h0fff_fff8 || expected_cluster<32'd2) begin
            if(dut.state!=4'd13) $fatal(1,"EOC/invalid entry did not finish directory scan");
        end else begin
            if(dut.state!=4'd4 || dut.dir_cluster!==expected_cluster)
                $fatal(1,"next directory cluster mismatch");
        end
        $display("PASS FAT capture offset=%0d entry=%h",byte_offset,entry_word);
    end
endtask

initial begin
    check_entry(9'd0,32'ha123_4567);
    check_entry(9'd8,32'h0000_0003);
    check_entry(9'd508,32'hffff_ffff);
    check_entry(9'd508,32'h0000_0000);
    $display("PASS shared-enable FAT capture");
    $finish;
end
initial begin
    #1000000;
    $fatal(1,"timeout");
end
endmodule
