// Prefetch from the synchronous-read EG_LOGIC_FIFO (REGMODE_R=NOREG).
// NOREG disables the EXTRA output register; it is not a FWFT interface.
module pcm_audio_player #(
    parameter integer PIXEL_CLOCK_HZ = 25_000_000,
    parameter integer SAMPLE_RATE_HZ = 48_000
) (
    input wire clk, input wire rst,
    input wire [31:0] fifo_dout, input wire fifo_empty,
    input wire [2:0] volume_level_async,
    output reg fifo_re, output reg audio_valid,
    output reg [23:0] left_pcm, output reg [23:0] right_pcm,
    output reg underrun
);
    localparam [31:0] CLOCK_RATE = PIXEL_CLOCK_HZ;
    localparam [31:0] SAMPLE_RATE = SAMPLE_RATE_HZ;
    reg [31:0] phase;
    wire [32:0] phase_sum = {1'b0,phase} + {1'b0,SAMPLE_RATE};
    wire sample_tick = phase_sum >= {1'b0,CLOCK_RATE};
    wire [32:0] phase_next = sample_tick ? phase_sum - {1'b0,CLOCK_RATE} : phase_sum;
    reg read_pending, sample_ready;
    reg [31:0] sample_buffer;
    reg [5:0] fallback_sample_count;
    reg [2:0] volume_meta, volume_sync;

    function [23:0] scale_pcm;
        input [15:0] sample;
        input [2:0] level;
        reg signed [26:0] expanded, scaled;
        begin
            // Left alignment preserves normalized PCM amplitude (16 -> 24).
            expanded = $signed({{3{sample[15]}}, sample, 8'd0});
            case(level)
                3'd0: scaled = 27'sd0;
                3'd1: scaled = expanded >>> 3;
                3'd2: scaled = expanded >>> 2;
                3'd3: scaled = expanded >>> 1;
                3'd4: scaled = expanded;
                3'd5: scaled = expanded + (expanded >>> 1);
                3'd6: scaled = expanded <<< 1;
                default: scaled = (expanded <<< 1) + (expanded >>> 1);
            endcase
            if (scaled > 27'sd8388607) scale_pcm = 24'h7fffff;
            else if (scaled < -27'sd8388608) scale_pcm = 24'h800000;
            else scale_pcm = scaled[23:0];
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            phase<=32'd0; fifo_re<=1'b0; audio_valid<=1'b0;
            left_pcm<=24'd0; right_pcm<=24'd0; underrun<=1'b0;
            read_pending<=1'b0; sample_ready<=1'b0; sample_buffer<=32'd0;
            fallback_sample_count<=6'd0;
            volume_meta<=3'd4; volume_sync<=3'd4;
        end else begin
            volume_meta<=volume_level_async; volume_sync<=volume_meta;
            phase<=phase_next[31:0];
            fifo_re<=1'b0;
            // fifo_re is consumed at THIS edge; capture its data NEXT edge.
            read_pending<=fifo_re && !fifo_empty;
            if (!sample_ready && !read_pending && !fifo_re && !fifo_empty)
                fifo_re<=1'b1;
            if (read_pending) begin
                sample_buffer<=fifo_dout;
                sample_ready<=1'b1;
            end
            // Keep HDMI/ACR at 48 kHz even on startup or SD underflow.
            audio_valid<=sample_tick;
            if (sample_tick) begin
                if (sample_ready) begin
                    left_pcm<=scale_pcm(sample_buffer[15:0],volume_sync);
                    right_pcm<=scale_pcm(sample_buffer[31:16],volume_sync);
                    sample_ready<=1'b0;
                end else begin
                    if (fallback_sample_count < 6'd24) begin
                        left_pcm<=24'sd1000000; right_pcm<=24'sd1000000;
                    end else begin
                        left_pcm<=-24'sd1000000; right_pcm<=-24'sd1000000;
                    end
                    if (fallback_sample_count == 6'd47) fallback_sample_count<=6'd0;
                    else fallback_sample_count<=fallback_sample_count + 1'b1;
                    underrun<=1'b1;
                end
            end
        end
    end
endmodule
