`timescale 1ns/1ps

// A bin-matched waveform must energize its corresponding displayed band;
// silence afterwards must cause the same band to decay.
module tb_audio_spectrum_analyzer;
reg clk = 0;
reg rst = 1;
reg sample_valid = 0;
reg [23:0] sample_pcm = 0;
wire [63:0] bands;
integer n;

always #5 clk = ~clk;

audio_spectrum_analyzer dut(
    .clk(clk), .rst(rst), .sample_valid(sample_valid),
    .sample_pcm(sample_pcm), .bands(bands)
);

task send_sample;
    input signed [23:0] value;
    begin
        @(negedge clk); sample_pcm = value; sample_valid = 1'b1;
        @(negedge clk); sample_valid = 1'b0;
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 0;
    // Matches bin 7's four-samples-positive/four-samples-negative kernel.
    for (n=0; n<64; n=n+1)
        send_sample((n[2] == 1'b0) ? 24'sd1000000 : -24'sd1000000);
    if (bands[63:56] < 8'd100)
        $fatal(1, "bin-matched PCM did not produce a spectrum peak");
    // Two analysis frames account for the intentional release smoothing.
    for (n=0; n<128; n=n+1) send_sample(24'sd0);
    if (bands[63:56] >= 8'd100)
        $fatal(1, "spectrum level did not respond to changed PCM data");
    $display("PASS: spectrum follows PCM frequency content and decay");
    $finish;
end
endmodule
