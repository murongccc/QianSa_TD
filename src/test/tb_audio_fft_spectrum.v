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
real angle;
reg [255:0] old_bands;
always #5 clk=~clk;

audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS)) dut (
    .clk(clk), .rst(rst), .sample_valid(sample_valid),
    .sample_pcm(sample_pcm), .frame_start(frame_start), .bands(bands)
);

task feed_frame;
    input integer tone_a;
    input integer tone_b;
    integer k;
    begin
        for (k=0;k<FFT_POINTS;k=k+1) begin
            angle=6.283185307179586*k/FFT_POINTS;
            val=$rtoi(3500000.0*$sin(angle*tone_a));
            if (tone_b != 0) val=val+$rtoi(3500000.0*$sin(angle*tone_b));
            @(negedge clk); sample_pcm=val; sample_valid=1;
            @(negedge clk); sample_valid=0;
            repeat (78) @(negedge clk);
        end
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

    feed_frame(0,0);
    publish_frame;
    if (bands[7*8 +: 8] >= 8'd80 ||
        bands[((FFT_POINTS == 512) ? 21 : 24)*8 +: 8] >= 8'd80)
        $fatal(1,"silence release did not start");
    rst=1;
    repeat (3) @(negedge clk);
    if (bands !== 256'd0) $fatal(1,"reset did not clear spectrum");
    $display("PASS FFT spectrum: tones, buffering, frame update, decay, reset");
    $finish;
end

initial begin
    #10000000;
    $fatal(1,"FFT test timeout");
end
endmodule
