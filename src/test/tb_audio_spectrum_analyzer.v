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
        // The board supplies 48 kHz PCM to a 25 MHz video clock domain.
        // Wait for the sequential eight-bin implementation to finish before
        // presenting the next sample, matching that real timing margin.
        while (dut.processing) @(negedge clk);
        @(negedge clk); sample_pcm = value; sample_valid = 1'b1;
        @(negedge clk); sample_valid = 1'b0;
        while (dut.processing) @(negedge clk);
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 0;
    send_sample(24'sd0);
    if (dut.phase[0] != 6'd1 || dut.phase[1] != 6'd2 ||
        dut.phase[2] != 6'd3 || dut.phase[3] != 6'd4 ||
        dut.phase[4] != 6'd5 || dut.phase[5] != 6'd6 ||
        dut.phase[6] != 6'd7 || dut.phase[7] != 6'd8)
        $fatal(1, "sequential bin phases did not all advance");
    rst = 1'b1;
    repeat (2) @(posedge clk);
    rst = 1'b0;

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
