`timescale 1ns/1ps

module tb_audio_fft_spectrum;
parameter integer FFT_POINTS = 512;
reg clk=0, rst=1, sample_valid=0, frame_start=0;
reg [23:0] sample_pcm=0;
wire [255:0] bands;
integer n;
integer val;
integer max_bin;
integer max_level;
integer weak_band;
integer weak_first;
integer weak_second;
integer before_silence;
real angle;
reg [255:0] old_bands;
always #5 clk=~clk;

audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS)) dut (
    .clk(clk), .rst(rst), .sample_valid(sample_valid),
    .sample_pcm(sample_pcm), .frame_start(frame_start), .bands(bands)
);

task feed_frame_level;
    input integer tone_a;
    input integer tone_b;
    input integer amplitude;
    integer k;
    begin
        for (k=0;k<FFT_POINTS;k=k+1) begin
            angle=6.283185307179586*k/FFT_POINTS;
            val=$rtoi(amplitude*$sin(angle*tone_a));
            if (tone_b != 0) val=val+$rtoi(amplitude*$sin(angle*tone_b));
            @(negedge clk); sample_pcm=val; sample_valid=1;
            @(negedge clk); sample_valid=0;
            repeat (78) @(negedge clk);
        end
    end
endtask

task feed_frame;
    input integer tone_a;
    input integer tone_b;
    begin
        feed_frame_level(tone_a,tone_b,3500000);
    end
endtask

task publish_frame;
    begin
        wait(dut.pending_valid);
        old_bands=bands;
        repeat (3) @(negedge clk);
        if (bands !== old_bands) $fatal(1,"bands changed before video frame");
        frame_start=1;
        @(negedge clk); frame_start=0;
        repeat (2) @(negedge clk);
    end
endtask

initial begin
    repeat (4) @(negedge clk); rst=0;
    feed_frame(8,0);
    publish_frame;
    max_bin=0; max_level=0;
    for (n=0;n<32;n=n+1)
        if (bands[n*8 +: 8] > max_level) begin
            max_level=bands[n*8 +: 8]; max_bin=n;
        end
    if (max_bin != 7 || max_level < 8'd30)
        $fatal(1,"single tone peak mismatch: band=%0d level=%0d",max_bin,max_level);

    feed_frame(8,40);
    publish_frame;
    if (bands[7*8 +: 8] < 8'd25 ||
        bands[((FFT_POINTS == 512) ? 21 : 24)*8 +: 8] < 8'd25)
        $fatal(1,"dual tone missing: low=%0d high=%0d",bands[7*8 +: 8],
               bands[((FFT_POINTS == 512) ? 21 : 24)*8 +: 8]);

    // 高频弱音应有可见幅度，但连续帧上升不能一次跳到目标值。
    weak_band=(FFT_POINTS == 512) ? 25 : 28;
    feed_frame_level(80,0,200000);
    publish_frame;
    weak_first=bands[weak_band*8 +: 8];
    if (weak_first < 8'd24 || weak_first > 8'd80)
        $fatal(1,"weak high tone visibility/attack mismatch: %0d",weak_first);
    feed_frame_level(80,0,200000);
    publish_frame;
    weak_second=bands[weak_band*8 +: 8];
    if (weak_second <= weak_first || weak_second > 8'd120)
        $fatal(1,"weak tone attack is unstable: %0d -> %0d",weak_first,weak_second);
    before_silence=weak_second;
    feed_frame(0,0);
    publish_frame;
    if (bands[weak_band*8 +: 8] >= before_silence ||
        bands[weak_band*8 +: 8] < (before_silence*3/4))
        $fatal(1,"silence release is unstable: %0d -> %0d",
               before_silence,bands[weak_band*8 +: 8]);
    for (n=0;n<40;n=n+1) begin
        feed_frame(0,0);
        publish_frame;
    end
    if (bands !== 256'd0) $fatal(1,"spectrum did not settle to silence");
    rst=1;
    repeat (3) @(negedge clk);
    if (bands !== 256'd0) $fatal(1,"reset did not clear spectrum");
    $display("PASS FFT spectrum: tones, weak highs, smoothed attack/release, buffering, reset");
    $finish;
end

initial begin
    #100000000;
    $fatal(1,"FFT test timeout");
end
endmodule
