// Direct 48 kHz PCM generator.  This replaces the former I2S-generator /
// I2S-receiver loop with a single, clock-enabled audio source.
module pcm_playlist_engine #(
    parameter integer PIXEL_CLOCK_HZ  = 25_000_000,
    parameter integer SAMPLE_RATE_HZ  = 48_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  image_slot_async,
    input  wire [2:0]  volume_level_async,
    output reg         audio_valid,
    output reg [23:0]  left_pcm,
    output reg [23:0]  right_pcm
);

reg [1:0] slot_sync0;
reg [1:0] slot_sync1;
reg [1:0] playing_slot;
reg [25:0] sample_phase;
reg [31:0] tone_phase;
reg [15:0] accent_samples;
reg signed [23:0] sample_value;
// volume_level_async is held stable in the UART clock domain between commands.
// These two stages isolate it from the video/audio clock domain.
reg [2:0] volume_meta;
reg [2:0] volume_sync;

wire [26:0] phase_sum = sample_phase + SAMPLE_RATE_HZ;
wire sample_tick = (phase_sum >= PIXEL_CLOCK_HZ);

function [31:0] note_step;
    input [1:0] slot;
    begin
        // C4, E4 and G4 phase increments for a 32-bit DDS at 48 kHz.
        case (slot)
            2'd0: note_step = 32'd23409862;
            2'd1: note_step = 32'd29494578;
            default: note_step = 32'd35075155;
        endcase
    end
endfunction

// This shift/add mapping is intentionally monotonic.  It avoids the mixed
// signed/unsigned multiplication that previously made adjacent UART levels
// sound inconsistent.  The maximum source amplitude is 3,000,000, so level 7
// (2.5x) remains within signed 24-bit PCM range during the transition cue.
function signed [23:0] apply_volume;
    input signed [23:0] sample;
    input [2:0] level;
    begin
        case (level)
            3'd0:   apply_volume = 24'sd0;
            3'd1:   apply_volume = sample >>> 3;
            3'd2:   apply_volume = sample >>> 2;
            3'd3:   apply_volume = sample >>> 1;
            3'd4:   apply_volume = sample;
            3'd5:   apply_volume = sample + (sample >>> 1);
            3'd6:   apply_volume = sample <<< 1;
            default:apply_volume = (sample <<< 1) + (sample >>> 1);
        endcase
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        slot_sync0     <= 2'd0;
        slot_sync1     <= 2'd0;
        playing_slot   <= 2'd0;
        sample_phase   <= 26'd0;
        tone_phase     <= 32'd0;
        accent_samples <= 16'd0;
        sample_value   <= 24'sd0;
        volume_meta    <= 3'd4;
        volume_sync    <= 3'd4;
        audio_valid    <= 1'b0;
        left_pcm       <= 24'd0;
        right_pcm      <= 24'd0;
    end else begin
        slot_sync0  <= image_slot_async;
        slot_sync1  <= slot_sync0;
        audio_valid <= 1'b0;

        if (sample_tick) begin
            sample_phase <= phase_sum - PIXEL_CLOCK_HZ;
            audio_valid  <= 1'b1;

            if (slot_sync1 != playing_slot) begin
                playing_slot   <= slot_sync1;
                accent_samples <= 16'd2400; // 50 ms transition cue
            end else if (accent_samples != 16'd0) begin
                accent_samples <= accent_samples - 16'd1;
            end

            tone_phase <= tone_phase + note_step(slot_sync1);
            if (accent_samples != 16'd0)
                sample_value <= tone_phase[31] ? -24'sd3000000 : 24'sd3000000;
            else
                sample_value <= tone_phase[31] ? -24'sd900000 : 24'sd900000;

            left_pcm  <= apply_volume(sample_value, volume_sync);
            right_pcm <= apply_volume(sample_value, volume_sync);
        end else begin
            sample_phase <= phase_sum;
        end
        volume_meta <= volume_level_async;
        volume_sync <= volume_meta;
    end
end

endmodule
