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
integer sweep_low;
integer sweep_mid;
integer sweep_high;
integer expected_band, tone_index, strength, repetition;
integer previous_level, measured_level, amplitude, previous_map, mapped, boundary;
real exact_map;
real angle;
reg [255:0] old_bands;
always #5 clk=~clk;

audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS)) dut (
    .clk(clk), .rst(rst), .sample_valid(sample_valid),
    .sample_pcm(sample_pcm), .frame_start(frame_start), .bands(bands), .bars()
);

function integer band_of_bin;
    input integer bin_number;
    integer j;
    begin
        band_of_bin=31;
        for (j=31;j>=0;j=j-1)
            if (bin_number <= dut.g_legacy.u_legacy.band_last(j)) band_of_bin=j;
    end
endfunction

task reset_analyzer;
    begin
        rst=1; repeat (3) @(negedge clk); rst=0;
    end
endtask

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

task feed_fractional_tone;
    input real tone_bin;
    input integer amplitude;
    integer k;
    begin
        for (k=0;k<FFT_POINTS;k=k+1) begin
            angle=6.283185307179586*k/FFT_POINTS;
            val=$rtoi(amplitude*$sin(angle*tone_bin));
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
        wait(dut.g_legacy.u_legacy.pending_valid);
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
    if (max_bin != band_of_bin(8) || max_level < 8'd30)
        $fatal(1,"single tone peak mismatch: band=%0d level=%0d",max_bin,max_level);

    feed_frame(8,40);
    publish_frame;
    if (bands[band_of_bin(8)*8 +: 8] < 8'd25 ||
        bands[band_of_bin(40)*8 +: 8] < 8'd25)
        $fatal(1,"dual tone missing");

    // 高频弱音应有可见幅度，但连续帧上升不能一次跳到目标值。
    weak_band=band_of_bin(dut.g_legacy.u_legacy.LAST_BIN-5);
    feed_frame_level(dut.g_legacy.u_legacy.LAST_BIN-5,0,200000);
    publish_frame;
    weak_first=bands[weak_band*8 +: 8];
    if (weak_first < 8'd24 || weak_first > 8'd100)
        $fatal(1,"weak high tone visibility/attack mismatch: %0d",weak_first);
    feed_frame_level(dut.g_legacy.u_legacy.LAST_BIN-5,0,200000);
    publish_frame;
    weak_second=bands[weak_band*8 +: 8];
    if (weak_second <= weak_first || weak_second > 8'd150)
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
    rst=0;
    feed_fractional_tone(8.25,500000);
    publish_frame;
    sweep_low=bands[band_of_bin(8)*8 +: 8]+bands[band_of_bin(9)*8 +: 8];
    if (bands[band_of_bin(4)*8 +: 8] > 8'd5)
        $fatal(1,"Hann window leaked into distant bin: %0d",bands[band_of_bin(4)*8 +: 8]);
    rst=1; repeat (3) @(negedge clk); rst=0;
    feed_fractional_tone(8.50,500000);
    publish_frame;
    sweep_mid=bands[band_of_bin(8)*8 +: 8]+bands[band_of_bin(9)*8 +: 8];
    if (bands[band_of_bin(4)*8 +: 8] > 8'd5)
        $fatal(1,"Hann window leaked at half bin: %0d",bands[band_of_bin(4)*8 +: 8]);
    rst=1; repeat (3) @(negedge clk); rst=0;
    feed_fractional_tone(8.75,500000);
    publish_frame;
    sweep_high=bands[band_of_bin(8)*8 +: 8]+bands[band_of_bin(9)*8 +: 8];
    if (sweep_low < 8'd20 || sweep_mid < 8'd20 || sweep_high < 8'd20 ||
        sweep_mid*2 < sweep_low || sweep_mid*2 < sweep_high)
        $fatal(1,"frequency sweep has a deep gap: %0d %0d %0d",
               sweep_low,sweep_mid,sweep_high);
    $display("PASS FFT spectrum: Hann sweep %0d/%0d/%0d, aggregation, buffering, silence",
             sweep_low,sweep_mid,sweep_high);
    // 扫描所有非空频段，验证最高段及采样缓冲复用。
    for (n=0;n<32;n=n+1) begin
        if (dut.g_legacy.u_legacy.band_last(n) <= ((n==0) ? 0 : dut.g_legacy.u_legacy.band_last(n-1)))
            $fatal(1,"empty band %0d",n);
        boundary=(n==0) ? 1 : dut.g_legacy.u_legacy.band_last(n-1)+1;
        tone_index=(boundary+dut.g_legacy.u_legacy.band_last(n))/2;
        reset_analyzer;
        feed_frame_level(tone_index,0,2000000); publish_frame;
        if (bands[n*8 +: 8] < 8'd40) $fatal(1,"sweep missing band %0d",n);
    end
    if (dut.g_legacy.u_legacy.band_last(31) != ((FFT_POINTS==512) ? 75 : 85)) $fatal(1,"last band mismatch");
    if (FFT_POINTS==512) begin
        if (dut.g_legacy.u_legacy.band_last(0)!=1) $fatal(1,"512 low frequency resolution lost");
        reset_analyzer;
        feed_frame_level(110,0,3000000); publish_frame;
        if (bands!==256'd0) $fatal(1,"out-of-range tone displayed");
    end
    // 对数曲线全域单调；未饱和区与解析曲线误差不超过 3 级。
    previous_map=0;
    for (n=0;n<524288;n=n+1) begin
        mapped=dut.g_legacy.u_legacy.magnitude_to_level(n);
        if (mapped < previous_map) $fatal(1,"nonmonotonic map at %0d",n);
        if (n>32 && n<50000) begin
            exact_map=24.0*$ln(n/32.0)/$ln(2.0);
            if ((mapped-exact_map>3.0)||(exact_map-mapped>3.0))
                $fatal(1,"log error at %0d",n);
        end
        previous_map=mapped;
    end
    // 低、中、高频 -24/-18/-12/-6 dBFS：稳定等级必须递增且不能封顶。
    for (n=0;n<3;n=n+1) begin
        tone_index=(n==0) ? 3 : ((n==1) ? dut.g_legacy.u_legacy.LAST_BIN/2 : dut.g_legacy.u_legacy.LAST_BIN-5);
        expected_band=band_of_bin(tone_index);
        previous_level=0;
        for (strength=0;strength<4;strength=strength+1) begin
            amplitude=$rtoi(8388607.0*(10.0**((-24.0+strength*6.0)/20.0)));
            reset_analyzer;
            for (repetition=0;repetition<8;repetition=repetition+1) begin
                feed_frame_level(tone_index,0,amplitude); publish_frame;
                if (repetition==1 && bands[expected_band*8 +: 8]<8'd20)
                    $fatal(1,"attack not visible in two frames");
            end
            measured_level=bands[expected_band*8 +: 8];
            $display("DYNAMIC N=%0d bin=%0d dBFS=%0d level=%0d",FFT_POINTS,tone_index,-24+strength*6,measured_level);
            if (measured_level<=previous_level || measured_level>=255)
                $fatal(1,"amplitude progression clipped/stuck");
            previous_level=measured_level;
        end
    end
    // 人工直流偏置检查：Hann 会向 bin1 泄漏，仅记录，不改正常低音。
    reset_analyzer;
    for (n=0;n<FFT_POINTS;n=n+1) begin
        @(negedge clk); sample_pcm=24'd500000; sample_valid=1;
        @(negedge clk); sample_valid=0; repeat (78) @(negedge clk);
    end
    publish_frame;
    $display("DC_OFFSET N=%0d first_band=%0d",FFT_POINTS,bands[7:0]);
    // 在各新增计算阶段中途复位，旧中间值不能污染重新采样后的结果。
    for (strength=14;strength<=18;strength=strength+1) begin
        reset_analyzer;
        feed_frame_level(8,0,2000000);
        wait(dut.g_legacy.u_legacy.state==strength);
        reset_analyzer;
        if (bands!==256'd0 || dut.g_legacy.u_legacy.pending_valid!==1'b0)
            $fatal(1,"mid-pipeline reset leaked output");
        feed_frame_level(8,0,2000000); publish_frame;
        if (bands[band_of_bin(8)*8 +: 8]<8'd40)
            $fatal(1,"mid-pipeline reset recovery failed at %0d",strength);
    end
    $display("PASS full spectrum regression N=%0d",FFT_POINTS);
    $finish;
end

initial begin
    #500000000;
    $fatal(1,"FFT test timeout");
end
endmodule
