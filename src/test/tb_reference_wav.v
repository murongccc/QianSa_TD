`timescale 1ns/1ps
// 完整音乐输入直达 FFT，记录 80 个最终等级用于渲染和比较。
module tb_reference_wav;
parameter integer FFT_POINTS=1024;
reg clk=0,rst=1,sample_valid=0,frame_start=0;
reg [23:0] sample_pcm=0;
wire [639:0] bars;
reg [23:0] samples [0:599999];
reg [2047:0] sample_path,output_path;
integer sample_total,n,gap,out_file,b;
always #5 clk=~clk;
audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS),.REFERENCE_MODE(1)) dut(
    .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),
    .frame_start(frame_start),.bars(bars),.bands());
initial begin
    if(!$value$plusargs("SAMPLES=%s",sample_path) || !$value$plusargs("OUTPUT=%s",output_path)
        || !$value$plusargs("COUNT=%d",sample_total)) $fatal(1,"missing WAV arguments");
    if(sample_total<1 || sample_total>600000) $fatal(1,"invalid count");
    $readmemh(sample_path,samples,0,sample_total-1);
    out_file=$fopen(output_path,"w");if(!out_file) $fatal(1,"cannot open output");
    $fwrite(out_file,"sample");for(b=0;b<80;b=b+1) $fwrite(out_file,",b%0d",b);$fwrite(out_file,"\n");
    repeat(4) @(negedge clk);rst=0;
    repeat(150) @(negedge clk);
    for(n=0;n<sample_total;n=n+1) begin
        @(negedge clk);sample_pcm=samples[n];sample_valid=1;
        @(negedge clk);sample_valid=0;
        for(gap=0;gap<78;gap=gap+1) begin
            @(negedge clk);frame_start=(gap==0 && n%800==799);
            if(gap==2 && n%800==799) begin
                $fwrite(out_file,"%0d",n+1);
                for(b=0;b<80;b=b+1) $fwrite(out_file,",%0d",bars[b*8 +:8]);
                $fwrite(out_file,"\n");
            end
        end
    end
    $fclose(out_file);$display("PASS reference WAV %0d samples",sample_total);$finish;
end
initial begin #600000000;$fatal(1,"WAV timeout");end
endmodule
