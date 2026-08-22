// Video presentation, bounded brightness control, and on-screen level bars.
module video_presentation #(
    parameter integer ACTIVE_WIDTH = 640,
    parameter integer ACTIVE_HEIGHT = 480
)(
    input wire clk, input wire rst, input wire display_valid,
    input wire [1:0] display_slot_async,
    input wire [2:0] brightness_level_async,
    input wire [2:0] volume_level_async,
    input wire de, input wire vs, input wire [23:0] rgb_in,
    output reg [23:0] rgb_out
);
reg [1:0] slot_sync0, slot_sync1, active_slot;
reg vs_d, de_d;
reg [9:0] pixel_x, pixel_y, reveal_x;
reg [6:0] fade_level;
reg [2:0] brightness_meta, brightness_sync, volume_meta, volume_sync;
reg [2:0] brightness_seen, volume_seen;
reg [26:0] osd_count;
wire frame_start = vs & ~vs_d;
wire line_start = de & ~de_d;
wire slot_changed = (slot_sync1 != active_slot);

function [6:0] brightness_gain;
    input [2:0] level;
    begin
        // 50%..137.5%; level 4 retains the former 1.0x default.
        brightness_gain = 7'd32 + {level, 3'b000};
    end
endfunction
function [7:0] scale_component;
    input [7:0] component;
    input [6:0] level;
    reg [14:0] product;
    begin
        product = component * level;
        // Saturate, rather than truncate high bits on an overflow.
        if (product > 15'd16320) scale_component = 8'hff;
        else scale_component = product >> 6;
    end
endfunction

wire [13:0] combined_gain_product = fade_level * brightness_gain(brightness_sync);
wire [6:0] gain = combined_gain_product >> 6;
wire [23:0] faded_rgb = {
    scale_component(rgb_in[23:16], gain),
    scale_component(rgb_in[15:8], gain),
    scale_component(rgb_in[7:0], gain)
};
// Two eight-segment meters at x=16..167: brightness yellow y=16..29,
// volume green y=40..53.  The internal levels are 0..7, displayed as one
// through eight filled segments so the default level 4 is visually centred.
wire meter_area = (pixel_x >= 10'd16) && (pixel_x < 10'd168) &&
                  (((pixel_y >= 10'd16) && (pixel_y < 10'd30)) ||
                   ((pixel_y >= 10'd40) && (pixel_y < 10'd54)));
wire show_osd = (osd_count != 27'd0);
// Eight 16-pixel bars with 3-pixel gaps.  Explicit ranges avoid a divider in
// the video path, which keeps the overlay small and timing-friendly.
wire meter_fill = ((pixel_x >= 10'd16)  && (pixel_x < 10'd32))  ||
                  ((pixel_x >= 10'd35)  && (pixel_x < 10'd51))  ||
                  ((pixel_x >= 10'd54)  && (pixel_x < 10'd70))  ||
                  ((pixel_x >= 10'd73)  && (pixel_x < 10'd89))  ||
                  ((pixel_x >= 10'd92)  && (pixel_x < 10'd108)) ||
                  ((pixel_x >= 10'd111) && (pixel_x < 10'd127)) ||
                  ((pixel_x >= 10'd130) && (pixel_x < 10'd146)) ||
                  ((pixel_x >= 10'd149) && (pixel_x < 10'd165));
wire [2:0] meter_index = (pixel_x < 10'd35)  ? 3'd0 :
                         (pixel_x < 10'd54)  ? 3'd1 :
                         (pixel_x < 10'd73)  ? 3'd2 :
                         (pixel_x < 10'd92)  ? 3'd3 :
                         (pixel_x < 10'd111) ? 3'd4 :
                         (pixel_x < 10'd130) ? 3'd5 :
                         (pixel_x < 10'd149) ? 3'd6 : 3'd7;
wire meter_brightness = (pixel_y < 10'd30);
wire meter_on = meter_brightness ? (meter_index <= brightness_sync) :
                                    (meter_index <= volume_sync);
wire [23:0] meter_rgb = (!meter_fill) ? 24'h202020 :
                        meter_on ? (meter_brightness ? 24'hFFFF00 : 24'h00FF40) :
                                   24'h404040;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        slot_sync0 <= 2'd0; slot_sync1 <= 2'd0; active_slot <= 2'd0;
        vs_d <= 1'b0; de_d <= 1'b0; pixel_x <= 10'd0; pixel_y <= 10'd0;
        reveal_x <= ACTIVE_WIDTH; fade_level <= 7'd64;
        brightness_meta <= 3'd4; brightness_sync <= 3'd4; brightness_seen <= 3'd4;
        volume_meta <= 3'd4; volume_sync <= 3'd4; volume_seen <= 3'd4;
        osd_count <= 27'd0; rgb_out <= 24'd0;
    end else begin
        slot_sync0 <= display_slot_async; slot_sync1 <= slot_sync0;
        brightness_meta <= brightness_level_async; brightness_sync <= brightness_meta;
        volume_meta <= volume_level_async; volume_sync <= volume_meta;
        if ((brightness_sync != brightness_seen) || (volume_sync != volume_seen)) begin
            brightness_seen <= brightness_sync;
            volume_seen <= volume_sync;
            osd_count <= 27'd75_000_000;
        end else if (osd_count != 27'd0) begin
            osd_count <= osd_count - 27'd1;
        end
        vs_d <= vs; de_d <= de;
        if (frame_start) begin
            pixel_y <= 10'd0;
            if (slot_changed) begin
                active_slot <= slot_sync1; reveal_x <= 10'd0; fade_level <= 7'd8;
            end else begin
                if (reveal_x < ACTIVE_WIDTH - 10'd32) reveal_x <= reveal_x + 10'd32;
                else reveal_x <= ACTIVE_WIDTH;
                if (fade_level < 7'd56) fade_level <= fade_level + 7'd8;
                else fade_level <= 7'd64;
            end
        end
        if (line_start) begin
            pixel_x <= 10'd0;
            if (pixel_y < ACTIVE_HEIGHT - 1) pixel_y <= pixel_y + 10'd1;
        end else if (de) pixel_x <= pixel_x + 10'd1;
        if (!display_valid || !de || (pixel_x >= reveal_x)) rgb_out <= 24'd0;
        else if (show_osd && meter_area) rgb_out <= meter_rgb;
        else rgb_out <= faded_rgb;
    end
end
endmodule
