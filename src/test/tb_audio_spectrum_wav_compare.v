`timescale 1ns/1ps
// 同一段左声道 PCM 按 800 个采样一次的显示帧节奏重放。
// 80 拍采样间隔缩短仿真时间，但仍足够完成每块 256/512 点 FFT。
module tb_audio_spectrum_wav_compare;
parameter integer PIPELINED = 1;
parameter integer FFT_POINTS = 256;
reg clk=0, rst=1, sample_valid=0, frame_start=0;
reg [23:0] sample_pcm=0;
wire [255:0] bands;
reg [23:0] samples [0:599999];
reg [2047:0] sample_path, output_path, detail_path;
integer sample_total, sample_index, output_file, band_number, gap;
integer detail_file, raw_peak=0, raw_sum=0;
always #5 clk=~clk;
audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS)) dut (
    .clk(clk), .rst(rst), .sample_valid(sample_valid),
    .sample_pcm(sample_pcm), .frame_start(frame_start), .bands(bands), .bars()
);
always @(posedge clk) begin
    if (rst) begin raw_peak=0; raw_sum=0; end
    else if (dut.g_legacy.u_legacy.state==13) begin
        if (dut.g_legacy.u_legacy.scan_magnitude>raw_peak) raw_peak=dut.g_legacy.u_legacy.scan_magnitude;
        raw_sum=raw_sum+dut.g_legacy.u_legacy.scan_magnitude;
    end else if (dut.g_legacy.u_legacy.state==((PIPELINED!=0) ? 18 : 14)) begin
        $fwrite(detail_file,"%0d,%0d,%0d,%0d,%0d\n",sample_index+1,dut.g_legacy.u_legacy.band_index,raw_peak,raw_sum,dut.g_legacy.u_legacy.band_level);
        raw_peak=0; raw_sum=0;
    end
end
initial begin
    if (!$value$plusargs("SAMPLES=%s",sample_path) ||
        !$value$plusargs("OUTPUT=%s",output_path) ||
        !$value$plusargs("COUNT=%d",sample_total) ||
        !$value$plusargs("DETAIL=%s",detail_path)) $fatal(1,"missing WAV arguments");
    if (sample_total<1 || sample_total>600000) $fatal(1,"invalid sample count");
    $readmemh(sample_path,samples,0,sample_total-1);
    output_file=$fopen(output_path,"w");
    detail_file=$fopen(detail_path,"w");
    if (!output_file || !detail_file) $fatal(1,"cannot open output");
    $fwrite(detail_file,"sample,band,raw_peak,raw_sum,target\n");
    $fwrite(output_file,"sample");
    for (band_number=0;band_number<32;band_number=band_number+1)
        $fwrite(output_file,",b%0d",band_number);
    $fwrite(output_file,"\n");
    repeat (4) @(negedge clk); rst=0;
    for (sample_index=0;sample_index<sample_total;sample_index=sample_index+1) begin
        @(negedge clk); sample_pcm=samples[sample_index]; sample_valid=1;
        @(negedge clk); sample_valid=0;
        for (gap=0;gap<78;gap=gap+1) begin
            @(negedge clk);
            frame_start=(gap==0 && sample_index%800==799);
            if (gap==2 && sample_index%800==799) begin
                $fwrite(output_file,"%0d",sample_index+1);
                for (band_number=0;band_number<32;band_number=band_number+1)
                    $fwrite(output_file,",%0d",bands[band_number*8 +: 8]);
                $fwrite(output_file,"\n");
            end
        end
    end
    $fclose(output_file);
    $fclose(detail_file);
    $display("PASS WAV replay: %0d samples",sample_total);
    $finish;
end
initial begin
    #600000000;
    $fatal(1,"WAV replay timeout");
end
endmodule
