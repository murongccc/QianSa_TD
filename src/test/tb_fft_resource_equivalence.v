`timescale 1ns/1ps
// baseline_fft.v 由资源回归脚本从优化前提交提取；逐块验证数学结果与帧发布。
module tb_fft_resource_equivalence;
reg clk=0,rst=1,sample_valid=0,frame_start=0;
reg [23:0] sample_pcm=0;
wire [639:0] bars,baseline_bars;
wire [7:0] radius,baseline_radius;
integer n,k,block_index,sample_value;
real pi=3.141592653589793;
reg [639:0] old_bars;
reg [7:0] old_radius;
always #5 clk=~clk;
audio_fft_spectrum #(.FFT_POINTS(2048),.REFERENCE_MODE(1)) dut(
    .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),
    .frame_start(frame_start),.bars(bars),.bands(),.breath_radius(radius));
baseline_audio_fft_spectrum #(.FFT_POINTS(2048),.REFERENCE_MODE(1)) golden(
    .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),
    .frame_start(frame_start),.bars(baseline_bars),.bands(),.breath_radius(baseline_radius));

task reset_both;
    begin
        @(negedge clk);rst=1;sample_valid=0;frame_start=0;
        repeat(4) @(negedge clk);
        rst=0;
        wait(dut.g_reference.u_reference.state==0 && golden.g_reference.u_reference.state==0);
        @(negedge clk);
    end
endtask
task compare_block;
    input integer pattern;
    begin
        old_bars=bars;old_radius=radius;
        for(n=0;n<2048;n=n+1) begin
            case(pattern)
                0: sample_value=0;
                1: sample_value=$rtoi(8192*$sin(2*pi*3*n/2048));
                2: sample_value=$rtoi(4096*$sin(2*pi*2*n/2048)+6144*$sin(2*pi*5*n/2048));
                3: sample_value=(n[0])?32767:-32768;
                4: sample_value=$rtoi(127*$sin(2*pi*17.25*n/2048));
                default: sample_value=((n*1103515245+12345)>>8)&65535;
            endcase
            @(negedge clk);sample_pcm=sample_value*256;sample_valid=1;
            @(negedge clk);sample_valid=0;
            repeat(78) @(negedge clk);
        end
        k=0;
        while((dut.g_reference.u_reference.state!=0 || golden.g_reference.u_reference.state!=0) && k<2048*520) begin
            @(negedge clk);k=k+1;
        end
        if(k==2048*520) $fatal(1,"processing missed production sample-block deadline");
        if(!dut.g_reference.u_reference.pending_valid || !golden.g_reference.u_reference.pending_valid)
            $fatal(1,"completed block missing pending publication");
        if(dut.g_reference.u_reference.bars_build!==golden.g_reference.u_reference.bars_build)
            $fatal(1,"bar values/order changed in pattern %0d",pattern);
        if(dut.g_reference.u_reference.radius_build!==golden.g_reference.u_reference.radius_build)
            $fatal(1,"breathing result changed in pattern %0d",pattern);
        if(bars!==old_bars || radius!==old_radius) $fatal(1,"visible result changed outside frame boundary");
        frame_start=1;
        @(negedge clk);frame_start=0;
        if(bars!==baseline_bars || radius!==baseline_radius) $fatal(1,"frame publication mismatch");
        $display("MATCH FFT block pattern=%0d radius=%0d",pattern,radius);
    end
endtask
initial begin
    reset_both;
    for(block_index=0;block_index<6;block_index=block_index+1) compare_block(block_index);
    compare_block(0);
    compare_block(0);
    // 运算中途复位后，不得发布复位前未完成的数据。
    @(negedge clk);sample_valid=1;sample_pcm=24'h7fffff;
    repeat(2048) @(negedge clk);
    sample_valid=0;
    repeat(100) @(negedge clk);
    reset_both;
    compare_block(2);
    $display("PASS FFT resource equivalence: bars, radius, frame publication, reset");
    $finish;
end
initial begin #200000000;$fatal(1,"equivalence timeout");end
endmodule
