// Lightweight real-time spectrum estimator for the 48 kHz PCM stream.
// Eight square-wave correlation bins are evaluated over 64 samples.  The
// resulting magnitudes are smoothed and exported as 0..255 bar heights.
//
// The video clock is 25 MHz while PCM arrives at 48 kHz, leaving more than
// 500 clocks between samples.  Process the eight bins over eight video-clock
// cycles instead of instantiating eight wide add/subtract datapaths.  This
// keeps the correlation formula unchanged and only delays a bands update by
// at most eight video clocks.
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
reg signed [24:0] sample_pending;
reg [2:0] bin_index;
reg processing;
integer i;

wire signed [30:0] sample_term = phase[bin_index][5] ?
    -{{6{sample_pending[24]}},sample_pending} : {{6{sample_pending[24]}},sample_pending};
wire signed [30:0] accum_next = accum[bin_index] + sample_term;
wire [30:0] magnitude_next = accum_next[30] ? -accum_next : accum_next;
wire [7:0] level_next = (magnitude_next > 31'd66846719) ?
    8'hff : magnitude_next[25:18];

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sample_index <= 0; bands <= 0; sample_pending <= 0;
        bin_index <= 0; processing <= 1'b0;
        for (i=0;i<8;i=i+1) begin accum[i] <= 0; phase[i] <= 0; end
    end else begin
        if (!processing) begin
            if (sample_valid) begin
                sample_pending <= $signed({sample_pcm[23],sample_pcm});
                bin_index <= 3'd0;
                processing <= 1'b1;
                sample_index <= (sample_index == BLOCK_SAMPLES-1) ? 0 : sample_index + 1'b1;
            end
        end else begin
            phase[bin_index] <= phase[bin_index] + bin_index + 1'b1;
            if (sample_index == 0) begin
                // A full-scale 24-bit tone correlated for 64 samples is
                // intentionally clamped; quieter material retains 8-bit
                // resolution after the 2^18 normalization.
                // Attack/release smoothing prevents flicker while retaining
                // direct response when the audio data changes.
                if (level_next > bands[bin_index*8 +: 8])
                    bands[bin_index*8 +: 8] <= level_next;
                else
                    bands[bin_index*8 +: 8] <= (bands[bin_index*8 +: 8] + level_next) >> 1;
                accum[bin_index] <= 0;
            end else begin
                accum[bin_index] <= accum_next;
            end

            if (bin_index == 3'd7) begin
                processing <= 1'b0;
            end else begin
                bin_index <= bin_index + 1'b1;
            end
        end
    end
end
endmodule
