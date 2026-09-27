`timescale 1ns/1ps
// 检查真实输入 FFT、直接频点映射、对数曲线、静音和帧同步。
module tb_reference_fft_spectrum;
parameter integer FFT_POINTS=1024;
reg clk=0,rst=1,sample_valid=0,frame_start=0;
reg [23:0] sample_pcm=0;
wire [639:0] bars;
wire [255:0] bands;
integer i,j,k,amplitude,peak,previous_peak,max_index,max_value;
integer out_file;
reg [639:0] saved_bars;
reg [2047:0] output_path;
real pi=3.141592653589793,argument,expected,error;
real scanned_real,scanned_imag;
integer expected_root=0;
reg [7:0] actual;
reg [15:0] position;
reg [31:0] root_square;
reg [639:0] observed_bars=0;
reg publication_allowed;
always #5 clk=~clk;
audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS),.REFERENCE_MODE(1)) dut(
    .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),
    .frame_start(frame_start),.bands(bands),.bars(bars));
always @(posedge clk) begin
    if(!rst && dut.g_reference.u_reference.state==13) begin
        scanned_real=$signed(dut.g_reference.u_reference.read_data[31:16]);
        scanned_imag=$signed(dut.g_reference.u_reference.read_data[15:0]);
        expected_root=$rtoi($sqrt(scanned_real*scanned_real+scanned_imag*scanned_imag));
    end
    if(!rst && dut.g_reference.u_reference.state==16)
        if(dut.g_reference.u_reference.sqrt_root!==expected_root[15:0])
            $fatal(1,"Euclidean magnitude mismatch");
end
always @(posedge clk) begin
    publication_allowed=frame_start && !dut.g_reference.u_reference.frame_start_d &&
        dut.g_reference.u_reference.pending_valid;
    #1;
    if(!rst && bars!==observed_bars && !publication_allowed)
        $fatal(1,"visible bars changed outside frame edge");
    observed_bars=bars;
end
task publish;
    begin
        @(negedge clk);frame_start=1;
        @(negedge clk);frame_start=0;
    end
endtask
task block;
    input real frequency;
    input integer gain;
    integer n,sample;
    begin
        for(n=0;n<FFT_POINTS;n=n+1) begin
            sample=$rtoi(gain*$sin(2*pi*frequency*n/48000));
            @(negedge clk);sample_valid=1;sample_pcm=sample*256;
            @(negedge clk);sample_valid=0;
            repeat(62) @(negedge clk);
        end
        k=0;
        while(dut.g_reference.u_reference.state!=0 && k<80000) begin
            @(negedge clk);k=k+1;
        end
        if(k==80000) $fatal(1,"FFT processing timeout");
        saved_bars=bars;
        repeat(5) @(negedge clk);
        if(bars!==saved_bars) $fatal(1,"bars changed outside frame boundary");
        publish;
    end
endtask
task peak_bar;
    begin
        max_value=0;max_index=0;
        for(j=0;j<80;j=j+1) if(bars[j*8 +:8]>max_value) begin
            max_value=bars[j*8 +:8];max_index=j;
        end
    end
endtask
initial begin
    if($value$plusargs("OUTPUT=%s",output_path)) out_file=$fopen(output_path,"w");
    else out_file=0;
    repeat(3) @(negedge clk);rst=0;
    repeat(150) @(negedge clk);
    if(bars!==0 || bands!==0) $fatal(1,"reset not silent");
    // 完整幅度范围：固定点曲线与浮点参考的误差不得超过 2 等级。
    previous_peak=0;
    for(i=0;i<=32768;i=i+1) begin
        argument=256+(i*7+5)/10;
        actual=dut.g_reference.u_reference.reference_level($rtoi(argument));
        expected=100*$ln(argument/256.0);
        if(expected>240) expected=240;
        error=actual-expected;
        if(error>2 || error< -2) $fatal(1,"log curve error input=%0d actual=%0d expected=%f",i,actual,expected);
        if(actual<previous_peak) $fatal(1,"log curve not monotonic");
        previous_peak=actual;
    end
    position=dut.g_reference.u_reference.reference_position(79);
    if(position<16'd34896 || position>16'd34899) $fatal(1,"upper frequency mapping");
    // 相同 FFT bin 的四级输入应产生不同显示等级，避免提前封顶。
    previous_peak=-1;
    for(i=0;i<4;i=i+1) begin
        amplitude=512<<i;
        repeat(8) block(3.0*48000/FFT_POINTS,amplitude);
        peak_bar;
        if(max_value<=previous_peak || max_value==240) $fatal(1,"amplitude response clipped/nonmonotonic");
        previous_peak=max_value;
        $display("AMPLITUDE N=%0d input=%0d peak=%0d column=%0d",FFT_POINTS,amplitude,max_value,max_index);
        if(out_file) $fwrite(out_file,"amplitude,%0d,%0d,%0d\n",amplitude,max_value,max_index);
    end
    // 频率升高，峰柱位置必须向高序号移动；非整数频点也必须完成扫描。
    previous_peak=-1;
    for(i=0;i<4;i=i+1) begin
        repeat(60) block(0,0);
        repeat(8) block(300.0*(1<<i)+13.0,8192);
        peak_bar;
        if(max_value==0 || max_index<=previous_peak) $fatal(1,"frequency order");
        previous_peak=max_index;
        $display("FREQUENCY %f peak column=%0d level=%0d",300.0*(1<<i)+13.0,max_index,max_value);
    end
    repeat(70) block(0,0);
    if(bars!==0) $fatal(1,"silence did not converge");
    repeat(8) block(9000,8192);
    peak_bar;
    if(max_value>10) $fatal(1,"out-of-range frequency visible");
    @(negedge clk);rst=1;
    @(negedge clk);
    if(bars!==0) $fatal(1,"reset retained bars");
    // 在蝶形运算中复位，缓存重新初始化后必须能正常接收下一块。
    @(negedge clk);rst=0;
    repeat(150) @(negedge clk);
    for(i=0;i<FFT_POINTS;i=i+1) begin
        @(negedge clk);sample_valid=1;sample_pcm=24'd500000;
        @(negedge clk);sample_valid=0;repeat(30) @(negedge clk);
    end
    wait(dut.g_reference.u_reference.state==7);
    @(negedge clk);rst=1;
    @(negedge clk);rst=0;
    repeat(150) @(negedge clk);
    if(bars!==0) $fatal(1,"mid-FFT reset retained display");
    repeat(4) block(1000,4096);
    peak_bar;if(max_value==0) $fatal(1,"mid-FFT reset did not recover");
    if(out_file) $fclose(out_file);
    $display("PASS reference FFT %0d",FFT_POINTS);$finish;
end
initial begin #1000000000;$fatal(1,"test timeout");end
endmodule
