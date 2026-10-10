`timescale 1ns/1ps
// 连续无匹配目录与跨簇 FAT 链，检查参数上限、128 扇区簇边界及取消前行为。
module tb_rhythm_priority1_directory;
    parameter integer LIMIT=1024,SPC=128;
    reg clk=0,rst=1,valid=0,done=0;
    reg [7:0] data=0;
    always #5 clk=~clk;
    wire req,old_req,busy,old_busy;
    wire [31:0] addr,old_addr;
    wire [3:0] error,old_error;
    fat32_chart_reader #(.MAX_DIRECTORY_SECTORS(LIMIT)) dut(
        .clk(clk),.rst(rst),.enable(1'b1),.cancel(1'b0),.volume_valid(1'b1),
        .volume_fat_start(32'd100),.volume_data_start(32'd200),.volume_root_cluster(32'd2),
        .volume_sectors_per_cluster(SPC[7:0]),.reserve_ready(1'b1),.sd_req(req),.sd_addr(addr),
        .sd_data(data),.sd_valid(valid),.sd_done(done),.note_we(),.note_data(),.header_valid(),
        .song_frames(),.note_count(),.hold_count(),.offset_samples(),.title(),.difficulty(),
        .metadata_we(),.metadata_address(),.metadata_data(),.busy(busy),.eof(),.cancelled(),.error_code(error));
    fat32_chart_reader_baseline #(.MAX_DIRECTORY_SECTORS(LIMIT)) reference(
        .clk(clk),.rst(rst),.enable(1'b1),.cancel(1'b0),.volume_valid(1'b1),
        .volume_fat_start(32'd100),.volume_data_start(32'd200),.volume_root_cluster(32'd2),
        .volume_sectors_per_cluster(SPC[7:0]),.reserve_ready(1'b1),.sd_req(old_req),.sd_addr(old_addr),
        .sd_data(data),.sd_valid(valid),.sd_done(done),.note_we(),.note_data(),.header_valid(),
        .song_frames(),.note_count(),.hold_count(),.offset_samples(),.title(),.difficulty(),
        .metadata_we(),.metadata_address(),.metadata_data(),.busy(old_busy),.eof(),.cancelled(),.error_code(old_error));
    always @(negedge clk)begin
        #1;
        if(!rst && {req,addr,busy,error}!=={old_req,old_addr,old_busy,old_error})
            $fatal(1,"directory cycle mismatch limit=%0d spc=%0d",LIMIT,SPC);
    end
    integer i,cluster=2,directory_requests=0,fat_requests=0;
    reg [31:0] active_addr,next_cluster;
    initial forever begin
        wait(req && !rst);@(negedge clk);active_addr=addr;
        if(active_addr>=200)directory_requests=directory_requests+1;else fat_requests=fat_requests+1;
        next_cluster=cluster+1;
        for(i=0;i<512;i=i+1)begin
            data=8'he5;
            if(active_addr<200)begin
                data=8'hff;
                if(i/4==(cluster%128))data=next_cluster>>((i%4)*8);
            end
            valid=1;done=i==511;@(negedge clk);
        end
        valid=0;done=0;
        if(active_addr<200)cluster=cluster+1;
        wait(!req);@(negedge clk);
    end
    initial begin
        repeat(4)@(negedge clk);rst=0;
        wait(!busy && error!=0);@(negedge clk);
        if(error!=1 || directory_requests!=LIMIT || fat_requests!=(LIMIT-1)/SPC)
            $fatal(1,"directory bound requests=%0d fat=%0d error=%0d",directory_requests,fat_requests,error);
        $display("PASS priority1 directory: limit=%0d spc=%0d directory=%0d FAT=%0d",LIMIT,SPC,directory_requests,fat_requests);
        $finish;
    end
    initial begin #20000000;$fatal(1,"priority1 directory timeout");end
endmodule
