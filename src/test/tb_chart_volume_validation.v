`timescale 1ns/1ps
// 全部 256 种簇大小与非法根簇，验证固定集合校验等价且不发错误请求。
module tb_chart_volume_validation;
    reg clk=0,rst=1;
    reg [7:0] spc=0;
    reg [31:0] root=2;
    wire busy,req;
    wire [3:0] error;
    integer n;
    reg expected;
    always #5 clk=~clk;
    fat32_chart_reader dut(
        .clk(clk),.rst(rst),.enable(1'b1),.cancel(1'b0),.volume_valid(1'b1),
        .volume_fat_start(32'd100),.volume_data_start(32'd200),.volume_root_cluster(root),
        .volume_sectors_per_cluster(spc),.reserve_ready(1'b1),.sd_req(req),.sd_addr(),
        .sd_data(8'd0),.sd_valid(1'b0),.sd_done(1'b0),.busy(busy),.error_code(error),
        .note_we(),.note_data(),.header_valid(),.song_frames(),.note_count(),.hold_count(),
        .offset_samples(),.title(),.difficulty(),.metadata_we(),.metadata_address(),.metadata_data(),.eof(),.cancelled());
    task check;
        input accepted;
        begin
            rst=1;repeat(2)@(negedge clk);rst=0;repeat(2)@(negedge clk);
            if(busy!==accepted || error!==(accepted ? 4'd0 : 4'd2) || req)
                $fatal(1,"volume validation mismatch root=%d spc=%d",root,spc);
        end
    endtask
    initial begin
        for(n=0;n<256;n=n+1)begin spc=n;expected=n!=0 && (n & (n-1))==0;check(expected);end
        spc=1;root=0;check(0);root=1;check(0);
        $display("PASS chart volume validation: all 256 sector counts and invalid roots");$finish;
    end
endmodule
