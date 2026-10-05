`timescale 1ns/1ps
// 修改前 RTL 由脚本从 Git 提取；每拍检查真实 FFT、缓存读出及发布。
module tb_fft_display_equivalence;
parameter integer FFT_POINTS=2048;
reg clk=0,rst=1,sample_valid=0,frame_start=0;
reg [23:0] sample_pcm=0;
reg [6:0] address=0;
wire [639:0] golden_bars,unused_bars;
wire [7:0] radius,golden_radius,data;
wire valid,active;
reg published=0,expected_valid;
reg [7:0] expected_data;
integer cycle=0,n,b,sample,publications=0,k;
real pi=3.141592653589793;
always #5 clk=~clk;
audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS),.REFERENCE_MODE(1),.BLOCK_BARS(1)) dut(
    .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),.frame_start(frame_start),
    .bands(),.bars(unused_bars),.breath_radius(radius),.bars_read_address(address),
    .bars_read_data(data),.bars_read_valid(valid),.bars_active(active));
baseline_audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS),.REFERENCE_MODE(1)) golden(
    .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),.frame_start(frame_start),
    .bands(),.bars(golden_bars),.breath_radius(golden_radius));
always @(negedge clk)begin
    cycle=cycle+1;address=address+7'd1;
    frame_start=!rst && cycle%2003==0;
end
always @(posedge clk)begin
    expected_valid=published && address<80;
    expected_data=expected_valid ? golden_bars[address*8 +:8] : 8'd0;
    if(rst)published<=0;
    else if(frame_start && !golden.g_reference.u_reference.frame_start_d && golden.g_reference.u_reference.pending_valid)begin
        published<=1;publications=publications+1;
    end
    if(!rst && dut.g_reference.u_reference.state==23 &&
       dut.g_reference.u_reference.bar_level!==golden.g_reference.u_reference.bar_level)
        $fatal(1,"computed bar mismatch");
    #1;
    if(!rst)begin
        if({valid,data}!=={expected_valid,expected_data})$fatal(1,"cache read mismatch index=%d",address);
        if(radius!==golden_radius || active!==((|golden_bars) && published))$fatal(1,"publication/radius mismatch");
        if(dut.g_reference.u_reference.state!==golden.g_reference.u_reference.state ||
           dut.g_reference.u_reference.pending_valid!==golden.g_reference.u_reference.pending_valid)
            $fatal(1,"processing/publication timing changed");
        if(unused_bars!==0)$fatal(1,"wide mirror exists");
    end
end
task send_block;
    input integer pattern;
    begin
        for(n=0;n<FFT_POINTS;n=n+1)begin
            case(pattern)
                0:sample=0;
                1:sample=$rtoi(8192*$sin(2*pi*3*n/FFT_POINTS));
                2:sample=$rtoi(4096*$sin(2*pi*2*n/FFT_POINTS)+6144*$sin(2*pi*5*n/FFT_POINTS));
                3:sample=n[0] ? 32767 : -32768;
                default:sample=((n*1103515245+12345)>>8)&65535;
            endcase
            @(negedge clk);sample_valid=1;sample_pcm=sample*256;
            @(negedge clk);sample_valid=0;
            // 板级 25 MHz/48 kHz 的采样间隔约 520 拍，连续输入不插块间停顿。
            repeat(518)@(negedge clk);
        end
    end
endtask
initial begin
    repeat(4)@(negedge clk);#1;rst=0;
    wait(dut.g_reference.u_reference.state==0);
    for(b=0;b<5;b=b+1)send_block(b);
    send_block(0);send_block(0);
    wait(dut.g_reference.u_reference.state==0);
    repeat(4100)@(negedge clk);
    if(publications<5)$fatal(1,"too few real FFT publications");
    // 新一块运算中复位后继续真实输入，RAM 残留内容不得显示。
    send_block(2);repeat(100)@(negedge clk);#1;rst=1;
    repeat(4)@(negedge clk);#1;rst=0;
    wait(dut.g_reference.u_reference.state==0);
    send_block(1);wait(dut.g_reference.u_reference.state==0);
    repeat(4100)@(negedge clk);
    $display("PASS FFT %0d: every bar/read, radius, publication cycle, continuous input and reset",FFT_POINTS);$finish;
end
initial begin #200000000;$fatal(1,"FFT equivalence timeout");end
endmodule
