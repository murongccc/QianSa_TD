// Video presentation: brightness control, level bars, and a two-layer OSD.
// The subtitle overlay stays entirely in the video_clk domain.  It uses a
// translucent banner as layer 1 and a 5x7 scrolling text layer as layer 2,
// so the TF/SDRAM frame-read path and HDMI timing remain unchanged.
module video_presentation #(
    parameter integer ACTIVE_WIDTH = 640,
    parameter integer ACTIVE_HEIGHT = 480
)(
    input wire clk, input wire rst, input wire display_valid,
    input wire [1:0] display_slot_async,
    input wire [2:0] brightness_level_async,
    input wire [2:0] volume_level_async,
    input wire [63:0] spectrum_bands,
    input wire de, input wire vs, input wire [23:0] rgb_in,
    output reg [23:0] rgb_out
);
reg [1:0] slot_sync0, slot_sync1, active_slot;
reg vs_d, de_d;
reg [9:0] pixel_x, pixel_y, reveal_x;
reg [6:0] fade_level;
reg [2:0] brightness_meta, brightness_sync, volume_meta, volume_sync;
reg [63:0] spectrum_meta, spectrum_sync;
reg [2:0] brightness_seen, volume_seen;
reg [26:0] osd_count;
reg [18:0] subtitle_tick_count;
reg [8:0] subtitle_scroll_x;
wire frame_start = vs & ~vs_d;
wire line_start = de & ~de_d;
wire slot_changed = (slot_sync1 != active_slot);
// pixel_x is updated on the clock edge.  At the first active pixel of every
// line it still contains the previous line's terminal value (640), so use an
// explicit zero coordinate for that cycle.  Otherwise the reveal mask treats
// the leftmost column as out of range after a slide transition.
wire [9:0] render_x = line_start ? 10'd0 : pixel_x;

localparam [9:0] SUBTITLE_TOP = 10'd428;
localparam [9:0] SUBTITLE_BOTTOM = 10'd462;
localparam [9:0] SUBTITLE_TEXT_TOP = 10'd438;
// 25 MHz pixel clock / 312500 = 80 pixels per second.  A 512-pixel message
// period completes in 6.4 seconds and repeats without a visible jump.
localparam [18:0] SUBTITLE_TICK_CYCLES = 19'd312500;

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

// Fixed 32-character message.  Five trailing blanks make its 16-pixel cells
// fill exactly 512 pixels, allowing a cheap power-of-two wrap for scrolling.
function [7:0] subtitle_char;
    input [4:0] index;
    begin
        case (index)
            5'd0: subtitle_char = "A";  5'd1: subtitle_char = "N";
            5'd2: subtitle_char = "L";  5'd3: subtitle_char = "O";
            5'd4: subtitle_char = "G";  5'd5: subtitle_char = "I";
            5'd6: subtitle_char = "C";  5'd7: subtitle_char = " ";
            5'd8: subtitle_char = "H";  5'd9: subtitle_char = "D";
            5'd10: subtitle_char = "M"; 5'd11: subtitle_char = "I";
            5'd12: subtitle_char = " "; 5'd13: subtitle_char = "M";
            5'd14: subtitle_char = "U"; 5'd15: subtitle_char = "L";
            5'd16: subtitle_char = "T"; 5'd17: subtitle_char = "I";
            5'd18: subtitle_char = "M"; 5'd19: subtitle_char = "E";
            5'd20: subtitle_char = "D"; 5'd21: subtitle_char = "I";
            5'd22: subtitle_char = "A"; 5'd23: subtitle_char = " ";
            5'd24: subtitle_char = "O"; 5'd25: subtitle_char = "S";
            5'd26: subtitle_char = "D";
            default: subtitle_char = " ";
        endcase
    end
endfunction

// 5x7 bitmap glyph rows, MSB at the left edge.  Only the characters used by
// the fixed caption are stored, keeping this OSD implementable without ROM IP.
function [4:0] subtitle_font_row;
    input [7:0] character;
    input [2:0] row;
    begin
        case (character)
            "A": case (row) 0:subtitle_font_row=5'b01110; 1:subtitle_font_row=5'b10001; 2:subtitle_font_row=5'b10001; 3:subtitle_font_row=5'b11111; 4:subtitle_font_row=5'b10001; 5:subtitle_font_row=5'b10001; default:subtitle_font_row=5'b10001; endcase
            "C": case (row) 0:subtitle_font_row=5'b01111; 1:subtitle_font_row=5'b10000; 2:subtitle_font_row=5'b10000; 3:subtitle_font_row=5'b10000; 4:subtitle_font_row=5'b10000; 5:subtitle_font_row=5'b10000; default:subtitle_font_row=5'b01111; endcase
            "D": case (row) 0:subtitle_font_row=5'b11110; 1:subtitle_font_row=5'b10001; 2:subtitle_font_row=5'b10001; 3:subtitle_font_row=5'b10001; 4:subtitle_font_row=5'b10001; 5:subtitle_font_row=5'b10001; default:subtitle_font_row=5'b11110; endcase
            "E": case (row) 0:subtitle_font_row=5'b11111; 1:subtitle_font_row=5'b10000; 2:subtitle_font_row=5'b10000; 3:subtitle_font_row=5'b11110; 4:subtitle_font_row=5'b10000; 5:subtitle_font_row=5'b10000; default:subtitle_font_row=5'b11111; endcase
            "G": case (row) 0:subtitle_font_row=5'b01111; 1:subtitle_font_row=5'b10000; 2:subtitle_font_row=5'b10000; 3:subtitle_font_row=5'b10111; 4:subtitle_font_row=5'b10001; 5:subtitle_font_row=5'b10001; default:subtitle_font_row=5'b01110; endcase
            "H": case (row) 0:subtitle_font_row=5'b10001; 1:subtitle_font_row=5'b10001; 2:subtitle_font_row=5'b10001; 3:subtitle_font_row=5'b11111; 4:subtitle_font_row=5'b10001; 5:subtitle_font_row=5'b10001; default:subtitle_font_row=5'b10001; endcase
            "I": case (row) 0:subtitle_font_row=5'b11111; 1:subtitle_font_row=5'b00100; 2:subtitle_font_row=5'b00100; 3:subtitle_font_row=5'b00100; 4:subtitle_font_row=5'b00100; 5:subtitle_font_row=5'b00100; default:subtitle_font_row=5'b11111; endcase
            "L": case (row) 0:subtitle_font_row=5'b10000; 1:subtitle_font_row=5'b10000; 2:subtitle_font_row=5'b10000; 3:subtitle_font_row=5'b10000; 4:subtitle_font_row=5'b10000; 5:subtitle_font_row=5'b10000; default:subtitle_font_row=5'b11111; endcase
            "M": case (row) 0:subtitle_font_row=5'b10001; 1:subtitle_font_row=5'b11011; 2:subtitle_font_row=5'b10101; 3:subtitle_font_row=5'b10101; 4:subtitle_font_row=5'b10001; 5:subtitle_font_row=5'b10001; default:subtitle_font_row=5'b10001; endcase
            "N": case (row) 0:subtitle_font_row=5'b10001; 1:subtitle_font_row=5'b11001; 2:subtitle_font_row=5'b10101; 3:subtitle_font_row=5'b10011; 4:subtitle_font_row=5'b10001; 5:subtitle_font_row=5'b10001; default:subtitle_font_row=5'b10001; endcase
            "O": case (row) 0:subtitle_font_row=5'b01110; 1:subtitle_font_row=5'b10001; 2:subtitle_font_row=5'b10001; 3:subtitle_font_row=5'b10001; 4:subtitle_font_row=5'b10001; 5:subtitle_font_row=5'b10001; default:subtitle_font_row=5'b01110; endcase
            "S": case (row) 0:subtitle_font_row=5'b01111; 1:subtitle_font_row=5'b10000; 2:subtitle_font_row=5'b10000; 3:subtitle_font_row=5'b01110; 4:subtitle_font_row=5'b00001; 5:subtitle_font_row=5'b00001; default:subtitle_font_row=5'b11110; endcase
            "T": case (row) 0:subtitle_font_row=5'b11111; 1:subtitle_font_row=5'b00100; 2:subtitle_font_row=5'b00100; 3:subtitle_font_row=5'b00100; 4:subtitle_font_row=5'b00100; 5:subtitle_font_row=5'b00100; default:subtitle_font_row=5'b00100; endcase
            "U": case (row) 0:subtitle_font_row=5'b10001; 1:subtitle_font_row=5'b10001; 2:subtitle_font_row=5'b10001; 3:subtitle_font_row=5'b10001; 4:subtitle_font_row=5'b10001; 5:subtitle_font_row=5'b10001; default:subtitle_font_row=5'b01110; endcase
            default: subtitle_font_row = 5'b00000;
        endcase
    end
endfunction

function subtitle_font_pixel;
    input [7:0] character;
    input [2:0] row;
    input [2:0] column;
    reg [4:0] glyph_row;
    begin
        glyph_row = subtitle_font_row(character, row);
        if ((row < 3'd7) && (column < 3'd5))
            subtitle_font_pixel = glyph_row[4-column];
        else
            subtitle_font_pixel = 1'b0;
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
wire meter_area = (render_x >= 10'd16) && (render_x < 10'd168) &&
                  (((pixel_y >= 10'd16) && (pixel_y < 10'd30)) ||
                   ((pixel_y >= 10'd40) && (pixel_y < 10'd54)));
wire show_osd = (osd_count != 27'd0);
// Eight 16-pixel bars with 3-pixel gaps.  Explicit ranges avoid a divider in
// the video path, which keeps the overlay small and timing-friendly.
wire meter_fill = ((render_x >= 10'd16)  && (render_x < 10'd32))  ||
                  ((render_x >= 10'd35)  && (render_x < 10'd51))  ||
                  ((render_x >= 10'd54)  && (render_x < 10'd70))  ||
                  ((render_x >= 10'd73)  && (render_x < 10'd89))  ||
                  ((render_x >= 10'd92)  && (render_x < 10'd108)) ||
                  ((render_x >= 10'd111) && (render_x < 10'd127)) ||
                  ((render_x >= 10'd130) && (render_x < 10'd146)) ||
                  ((render_x >= 10'd149) && (render_x < 10'd165));
wire [2:0] meter_index = (render_x < 10'd35)  ? 3'd0 :
                         (render_x < 10'd54)  ? 3'd1 :
                         (render_x < 10'd73)  ? 3'd2 :
                         (render_x < 10'd92)  ? 3'd3 :
                         (render_x < 10'd111) ? 3'd4 :
                         (render_x < 10'd130) ? 3'd5 :
                         (render_x < 10'd149) ? 3'd6 : 3'd7;
wire meter_brightness = (pixel_y < 10'd30);
wire meter_on = meter_brightness ? (meter_index <= brightness_sync) :
                                    (meter_index <= volume_sync);
wire [23:0] meter_rgb = (!meter_fill) ? 24'h202020 :
                        meter_on ? (meter_brightness ? 24'hFFFF00 : 24'h00FF40) :
                                   24'h404040;

// Compact audio spectrum in the upper-right corner.  Eight 16-pixel bars
// share a 3-pixel gap and a common 80-pixel baseline, keeping the overlay
// readable without consuming the central image area.
wire spectrum_area = (render_x >= 10'd480) && (render_x < 10'd632) &&
                     (pixel_y >= 10'd24) && (pixel_y < 10'd104);
wire [9:0] spectrum_rel_x = (render_x < 10'd480) ? 10'd0 : (render_x - 10'd480);
wire [2:0] spectrum_index = (spectrum_rel_x >= 10'd133) ? 3'd7 :
                             (spectrum_rel_x >= 10'd114) ? 3'd6 :
                             (spectrum_rel_x >= 10'd95)  ? 3'd5 :
                             (spectrum_rel_x >= 10'd76)  ? 3'd4 :
                             (spectrum_rel_x >= 10'd57)  ? 3'd3 :
                             (spectrum_rel_x >= 10'd38)  ? 3'd2 :
                             (spectrum_rel_x >= 10'd19)  ? 3'd1 : 3'd0;
wire [4:0] spectrum_bar_x = (spectrum_rel_x >= 10'd133) ? spectrum_rel_x - 10'd133 :
                             (spectrum_rel_x >= 10'd114) ? spectrum_rel_x - 10'd114 :
                             (spectrum_rel_x >= 10'd95)  ? spectrum_rel_x - 10'd95  :
                             (spectrum_rel_x >= 10'd76)  ? spectrum_rel_x - 10'd76  :
                             (spectrum_rel_x >= 10'd57)  ? spectrum_rel_x - 10'd57  :
                             (spectrum_rel_x >= 10'd38)  ? spectrum_rel_x - 10'd38  :
                             (spectrum_rel_x >= 10'd19)  ? spectrum_rel_x - 10'd19  :
                             spectrum_rel_x[4:0];
wire spectrum_bar_column = spectrum_bar_x < 5'd16;
wire [7:0] spectrum_level = spectrum_sync[spectrum_index*8 +: 8];
wire [7:0] spectrum_height = spectrum_level[7:2];
wire spectrum_on = spectrum_area && spectrum_bar_column &&
                   ({1'b0,pixel_y} >= (10'd104 - {2'b00,spectrum_height}));
wire [23:0] spectrum_rgb = (spectrum_index < 3'd3) ? 24'h00D8FF :
                           (spectrum_index < 3'd6) ? 24'h40FF40 : 24'hFFB000;

// Subtitle alpha background: 25% black + the original pixel, then opaque
// yellow text.  This gives a readable two-layer overlay without a multiplier.
wire subtitle_banner_area = (pixel_y >= SUBTITLE_TOP) && (pixel_y < SUBTITLE_BOTTOM);
wire [9:0] subtitle_virtual_x = {1'b0, render_x} + {1'b0, subtitle_scroll_x};
wire [7:0] subtitle_character = subtitle_char(subtitle_virtual_x[8:4]);
wire [2:0] subtitle_glyph_column = subtitle_virtual_x[3:1];
wire [2:0] subtitle_glyph_row = (pixel_y - SUBTITLE_TEXT_TOP) >> 1;
wire subtitle_text_area = (pixel_y >= SUBTITLE_TEXT_TOP) &&
                          (pixel_y < (SUBTITLE_TEXT_TOP + 10'd14));
wire subtitle_text_pixel = subtitle_text_area &&
                           subtitle_font_pixel(subtitle_character, subtitle_glyph_row,
                                               subtitle_glyph_column);
wire [23:0] subtitle_banner_rgb = {
    (faded_rgb[23:16] >> 1) + (faded_rgb[23:16] >> 2),
    (faded_rgb[15:8]  >> 1) + (faded_rgb[15:8]  >> 2),
    (faded_rgb[7:0]   >> 1) + (faded_rgb[7:0]   >> 2)
};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        slot_sync0 <= 2'd0; slot_sync1 <= 2'd0; active_slot <= 2'd0;
        vs_d <= 1'b0; de_d <= 1'b0; pixel_x <= 10'd0; pixel_y <= 10'd0;
        reveal_x <= ACTIVE_WIDTH; fade_level <= 7'd64;
        brightness_meta <= 3'd4; brightness_sync <= 3'd4; brightness_seen <= 3'd4;
        volume_meta <= 3'd4; volume_sync <= 3'd4; volume_seen <= 3'd4;
        spectrum_meta <= 64'd0; spectrum_sync <= 64'd0;
        osd_count <= 27'd0;
        subtitle_tick_count <= 19'd0;
        subtitle_scroll_x <= 9'd0;
        rgb_out <= 24'd0;
    end else begin
        slot_sync0 <= display_slot_async; slot_sync1 <= slot_sync0;
        brightness_meta <= brightness_level_async; brightness_sync <= brightness_meta;
        volume_meta <= volume_level_async; volume_sync <= volume_meta;
        spectrum_meta <= spectrum_bands; spectrum_sync <= spectrum_meta;
        if ((brightness_sync != brightness_seen) || (volume_sync != volume_seen)) begin
            brightness_seen <= brightness_sync;
            volume_seen <= volume_sync;
            osd_count <= 27'd75_000_000;
        end else if (osd_count != 27'd0) begin
            osd_count <= osd_count - 27'd1;
        end
        if (subtitle_tick_count == SUBTITLE_TICK_CYCLES - 19'd1) begin
            subtitle_tick_count <= 19'd0;
            subtitle_scroll_x <= subtitle_scroll_x + 9'd1;
        end else begin
            subtitle_tick_count <= subtitle_tick_count + 19'd1;
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
            // This edge renders x=0 (render_x above), therefore keep x=1
            // for the following pixel.  Starting again at zero duplicates
            // the left edge and drops x=639 at the right edge.
            pixel_x <= 10'd1;
            if (pixel_y < ACTIVE_HEIGHT - 1) pixel_y <= pixel_y + 10'd1;
        end else if (de) pixel_x <= pixel_x + 10'd1;
        if (!display_valid || !de || (render_x >= reveal_x)) rgb_out <= 24'd0;
        else if (show_osd && meter_area) rgb_out <= meter_rgb;
        else if (spectrum_on) rgb_out <= spectrum_rgb;
        else if (subtitle_text_pixel) rgb_out <= 24'hFFE040;
        else if (subtitle_banner_area) rgb_out <= subtitle_banner_rgb;
        else rgb_out <= faded_rgb;
    end
end
endmodule
