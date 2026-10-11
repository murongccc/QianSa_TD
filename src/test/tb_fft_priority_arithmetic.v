`timescale 1ns/1ps
// 对照修改前 RTL：生产柱地址、正负差值、进位、并发采样和完整对数输入范围。
module tb_fft_priority_arithmetic;
reg clk=0,rst=1,sample_valid=0;
reg [23:0] pcm=0;
integer a,b,i,s,n,checks=0;
reg [18:0] boundary[0:13];
reg [18:0] av,bv;
always #5 clk=~clk;
reference_fft_spectrum #(.FFT_POINTS(2048)) dut(
    .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(pcm),.frame_start(1'b0),
    .bars(),.breath_radius(),.bars_read_address(7'd0),.bars_read_data(),.bars_read_valid(),.bars_active());
baseline_reference_fft_spectrum #(.FFT_POINTS(2048)) golden(
    .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(pcm),.frame_start(1'b0),
    .bars(),.breath_radius(),.bars_read_address(7'd0),.bars_read_data(),.bars_read_valid(),.bars_active());
initial begin
    boundary[0]=0;boundary[1]=1;boundary[2]=255;boundary[3]=256;
    boundary[4]=32767;boundary[5]=32768;boundary[6]=65535;boundary[7]=65536;
    boundary[8]=131071;boundary[9]=131072;boundary[10]=262143;boundary[11]=262144;
    boundary[12]=324380;boundary[13]=524287;
    repeat(4)@(negedge clk);rst=0;
    wait(dut.state==0 && golden.state==0);
    for(n=256;n<=52685;n=n+1)
        if(dut.reference_level(n)!==golden.reference_level(n))
            $fatal(1,"log arithmetic mismatch argument=%0d",n);
    for(a=0;a<14;a=a+1)for(s=0;s<32;s=s+1)begin
        @(negedge clk);dut.history_q={s[4:0],boundary[a]};golden.history_q={s[4:0],boundary[a]};
        dut.sqrt_root=0;golden.sqrt_root=0;
        #1;if({dut.smooth_magnitude,dut.next_fall_speed}!=={golden.smooth_magnitude,golden.next_fall_speed})
            $fatal(1,"fall mismatch held=%0d speed=%0d",boundary[a],s);
    end
    for(a=0;a<14;a=a+1)for(b=0;b<14;b=b+1)for(i=0;i<80;i=i+1)begin
        av=boundary[a];bv=boundary[b];
        @(negedge clk);
        dut.state=20;golden.state=20;dut.bar_index=i;golden.bar_index=i;
        dut.magnitude_a=av;golden.magnitude_a=av;dut.history_q={5'd0,bv};golden.history_q={5'd0,bv};
        sample_valid=checks[0];pcm=checks*1103515245+12345;
        @(posedge clk);#1;
        if(dut.state!==golden.state || dut.windowed_pcm!==golden.windowed_pcm)
            $fatal(1,"BAR_B schedule/Hann mismatch");
        @(negedge clk);sample_valid=!sample_valid;
        @(posedge clk);#1;
        if(dut.interpolated_product!==golden.interpolated_product[26:0] || golden.interpolated_product[27]!==0)
            $fatal(1,"blend mismatch A=%0d B=%0d index=%0d",av,bv,i);
        if(dut.state!==golden.state || dut.windowed_pcm!==golden.windowed_pcm)
            $fatal(1,"BLEND schedule/Hann mismatch");
        checks=checks+1;
    end
    sample_valid=0;
    $display("PASS priority arithmetic: 50430 log values, 448 fall cases, %0d blends with concurrent Hann",checks);
    $finish;
end
initial begin #10000000;$fatal(1,"arithmetic timeout");end
endmodule
