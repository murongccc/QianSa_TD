`timescale 1ns/1ps
// 同时翻转五路输入，验证轮询消抖保留独立状态、拒绝短毛刺并只产生一次下降沿脉冲。
module tb_rhythm_debounce_bank;
    reg clk=0;always #5 clk=~clk;
    reg rst=1;reg [4:0] async_in=5'b11100;
    wire [4:0] stable_level,fall_pulse;
    rhythm_control_debounce_bank #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(10)) dut(
        .clk(clk),.rst(rst),.async_in(async_in),.stable_level(stable_level),.fall_pulse(fall_pulse));
    integer pulse0=0,pulse1=0,pulse2=0,pulse3=0,pulse4=0;
    always @(posedge clk)begin
        if(fall_pulse[0])pulse0=pulse0+1;if(fall_pulse[1])pulse1=pulse1+1;
        if(fall_pulse[2])pulse2=pulse2+1;if(fall_pulse[3])pulse3=pulse3+1;if(fall_pulse[4])pulse4=pulse4+1;
    end
    initial begin
        repeat(3)@(negedge clk);rst=0;
        // 三拍毛刺短于任一路所需的两次扫描访问。
        async_in=5'b00011;repeat(3)@(negedge clk);async_in=5'b11100;repeat(15)@(negedge clk);
        if(stable_level!==5'b11100 || {pulse4,pulse3,pulse2,pulse1,pulse0}!==160'd0)$fatal(1,"short glitch accepted");
        // 五路同时变化；三只低有效按键各产生一个下降沿脉冲。
        async_in=5'b00011;repeat(20)@(negedge clk);
        if(stable_level!==5'b00011 || pulse2!=1 || pulse3!=1 || pulse4!=1 || pulse0!=0 || pulse1!=0)
            $fatal(1,"simultaneous debounce/fall pulse mismatch");
        // 同时回到复位电平，只有两个开关发生下降沿，且所有脉冲均保持单拍。
        async_in=5'b11100;repeat(20)@(negedge clk);
        if(stable_level!==5'b11100 || pulse0!=1 || pulse1!=1 || pulse2!=1 || pulse3!=1 || pulse4!=1)
            $fatal(1,"return transition mismatch");
        $display("PASS shared debounce: glitch rejection, five simultaneous inputs, one-shot fall pulses");$finish;
    end
    initial begin #2000;$fatal(1,"debounce timeout");end
endmodule
