// Presentation layer for the media player.
// It is deliberately separate from the SD/BMP loader: image loading and how a
// completed frame is presented on HDMI are independent responsibilities.
module video_presentation #(
    parameter integer ACTIVE_WIDTH  = 640,
    parameter integer ACTIVE_HEIGHT = 480
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        display_valid,
    input  wire [1:0]  display_slot_async,
    input  wire [6:0]  brightness_async,
    input  wire        de,
    input  wire        vs,
    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out
);

reg [1:0] slot_sync0;
reg [1:0] slot_sync1;
reg [1:0] active_slot;
reg       vs_d;
reg       de_d;
reg [9:0] pixel_x;
reg [9:0] pixel_y;
reg [9:0] reveal_x;
reg [6:0] fade_level;
reg [6:0] brightness_meta;
reg [6:0] brightness_sync;

wire frame_start = vs & ~vs_d;
wire line_start  = de & ~de_d;
wire slot_changed = (slot_sync1 != active_slot);
wire [6:0] transition_gain = (fade_level == 7'd0) ? 7'd1 : fade_level;
wire [13:0] combined_gain_product = transition_gain * brightness_sync;
wire [6:0] gain = combined_gain_product >> 6;

function [7:0] scale_component;
    input [7:0] component;
    input [6:0] level;
    reg [14:0] product;
    begin
        product = component * level;
        scale_component = product >> 6;
    end
endfunction

wire [23:0] faded_rgb = {
    scale_component(rgb_in[23:16], gain),
    scale_component(rgb_in[15:8],  gain),
    scale_component(rgb_in[7:0],   gain)
};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        slot_sync0  <= 2'd0;
        slot_sync1  <= 2'd0;
        active_slot <= 2'd0;
        vs_d        <= 1'b0;
        de_d        <= 1'b0;
        pixel_x     <= 10'd0;
        pixel_y     <= 10'd0;
        reveal_x    <= ACTIVE_WIDTH;
        fade_level  <= 7'd64;
        brightness_meta <= 7'd64;
        brightness_sync <= 7'd64;
        rgb_out     <= 24'd0;
    end else begin
        slot_sync0 <= display_slot_async;
        slot_sync1 <= slot_sync0;
        brightness_meta <= brightness_async;
        brightness_sync <= brightness_meta;
        vs_d       <= vs;
        de_d       <= de;

        if (frame_start) begin
            pixel_y <= 10'd0;
            if (slot_changed) begin
                active_slot <= slot_sync1;
                reveal_x    <= 10'd0;
                fade_level  <= 7'd8;
            end else begin
                if (reveal_x < ACTIVE_WIDTH - 10'd32)
                    reveal_x <= reveal_x + 10'd32;
                else
                    reveal_x <= ACTIVE_WIDTH;

                if (fade_level < 7'd56)
                    fade_level <= fade_level + 7'd8;
                else
                    fade_level <= 7'd64;
            end
        end

        if (line_start) begin
            pixel_x <= 10'd0;
            if (pixel_y < ACTIVE_HEIGHT - 1)
                pixel_y <= pixel_y + 10'd1;
        end else if (de) begin
            pixel_x <= pixel_x + 10'd1;
        end

        if (!display_valid || !de) begin
            rgb_out <= 24'd0;
        end else if (pixel_x >= reveal_x) begin
            // A new frame is revealed from left to right instead of switching
            // the visible buffer abruptly.
            rgb_out <= 24'd0;
        end else begin
            rgb_out <= faded_rgb;
        end
    end
end

endmodule
