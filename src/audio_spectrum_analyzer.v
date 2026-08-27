// Lightweight real-time spectrum estimator for the 48 kHz PCM stream.
// Eight square-wave correlation bins are evaluated over 64 samples.  The
// resulting magnitudes are smoothed and exported as 0..255 bar heights.
module audio_spectrum_analyzer #(
    parameter integer BLOCK_SAMPLES = 64
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        sample_valid,
    input  wire [23:0] sample_pcm,
    output reg  [63:0] bands
);
reg [5:0] sample_index;
reg signed [30:0] accum [0:7];
reg [5:0] phase [0:7];
integer i;
reg signed [24:0] sample_signed;
reg signed [30:0] next_accum;
reg [30:0] magnitude;
reg [7:0] level;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sample_index <= 0; bands <= 0;
        for (i=0;i<8;i=i+1) begin accum[i] <= 0; phase[i] <= 0; end
    end else if (sample_valid) begin
        sample_signed = $signed({sample_pcm[23],sample_pcm});
        for (i=0;i<8;i=i+1) begin
            next_accum = accum[i] + (phase[i][5] ? -sample_signed : sample_signed);
            phase[i] <= phase[i] + i + 1;
            if (sample_index == BLOCK_SAMPLES-1) begin
                magnitude = next_accum[30] ? -next_accum : next_accum;
                // A full-scale 24-bit tone correlated for 64 samples is
                // intentionally clamped; quieter material retains 8-bit
                // resolution after the 2^18 normalization.
                level = (magnitude > 31'd66846719) ? 8'hff : magnitude[25:18];
                // Attack/release smoothing prevents flicker while retaining
                // direct response when the audio data changes.
                if (level > bands[i*8 +: 8])
                    bands[i*8 +: 8] <= level;
                else
                    bands[i*8 +: 8] <= (bands[i*8 +: 8] + level) >> 1;
                accum[i] <= 0;
            end else begin
                accum[i] <= next_accum;
            end
        end
        sample_index <= (sample_index == BLOCK_SAMPLES-1) ? 0 : sample_index + 1;
    end
end
endmodule
