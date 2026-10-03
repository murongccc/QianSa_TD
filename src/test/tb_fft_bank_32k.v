`timescale 1ns/1ps
// 使用真实厂商 BRAM 模型检查迁移后的高地址、同步一拍与读使能保持语义。
module tb_fft_bank_32k;
    reg clk=0;always #5 clk=~clk;
    reg we=0,re=0;reg [10:0] wa=0,ra=0;reg [31:0] wd=0;
    wire [31:0] rd;
    reg [31:0] expected,reference[0:2047];
    reg check_read=0;
    integer i;
    fft_spectrum_bank_ram #(.DEPTH(2048),.ADDR_W(11)) dut(clk,we,wa,wd,re,ra,rd);
    always @(posedge clk)begin
        if(re)expected=reference[ra];
        if(we)reference[wa]=wd;
        #1;if(check_read && rd!==expected)$fatal(1,"FFT bank one-cycle/hold mismatch ra=%0d got=%h want=%h",ra,rd,expected);
    end
    initial begin
        for(i=0;i<2048;i=i+1)begin @(negedge clk);we=1;wa=i;wd=32'h89abcdef^(i*32'h01010101);end
        @(negedge clk);we=0;re=1;ra=2047;check_read=1;
        for(i=0;i<10000;i=i+1)begin
            @(negedge clk);ra=(i*541+1024)%2048;wa=(ra+773)%2048;
            wd=32'hfedcba98^(i*32'h31415927);we=i%3!=0;re=i%5!=0;
        end
        @(negedge clk);we=0;re=0;repeat(10)@(negedge clk);
        $display("PASS FFT BRAM32K bank: full 2048 addresses, one-cycle read, concurrent ports and disabled-read hold");$finish;
    end
    initial begin #1000000;$fatal(1,"FFT bank timeout");end
endmodule
