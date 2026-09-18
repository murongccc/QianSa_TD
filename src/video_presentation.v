// Video presentation: brightness control, level bars, and a two-layer OSD.
// The subtitle overlay stays entirely in the video_clk domain.  It uses a
// translucent banner as layer 1 and a 5x7 scrolling text layer as layer 2,
// so the TF/SDRAM frame-read path and HDMI timing remain unchanged.
module video_presentation #(
    parameter integer ACTIVE_WIDTH = 640,
    parameter integer ACTIVE_HEIGHT = 480,
    parameter integer OSD_DISPLAY_CYCLES = 50_000_000
)(
    input wire clk, input wire rst, input wire display_valid,
    input wire [1:0] display_slot_async,
    input wire display_switch_toggle_async,
    output reg display_slot_applied_toggle,
    input wire [2:0] brightness_level_async,
    input wire [6:0] image_brightness_async,
    input wire [6:0] image_contrast_async,
    input wire [6:0] image_sharpness_async,
    input wire [1:0] image_selected_async,
    input wire image_select_toggle_async,
    input wire image_adjust_toggle_async,
    input wire [63:0] spectrum_bands,
    input wire de, input wire vs, input wire [23:0] rgb_in,
    output reg [23:0] rgb_out
);
reg [1:0] slot_sync0, slot_sync1, active_slot;
reg display_switch_toggle_meta, display_switch_toggle_sync;
reg display_switch_toggle_seen;
reg vs_d, de_d;
reg display_valid_meta, display_valid_sync;
reg [9:0] pixel_x, pixel_y, reveal_x;
reg [6:0] fade_level;
reg [2:0] brightness_meta, brightness_sync;
reg [6:0] image_brightness_meta, image_brightness_sync;
reg [6:0] image_contrast_meta, image_contrast_sync;
reg [6:0] image_sharpness_meta, image_sharpness_sync;
reg [1:0] image_selected_meta, image_selected_sync;
reg image_select_toggle_meta, image_select_toggle_sync, image_select_toggle_seen;
reg image_adjust_toggle_meta, image_adjust_toggle_sync, image_adjust_toggle_seen;
reg [63:0] spectrum_meta, spectrum_sync;
reg [6:0] image_value_seen;
reg [1:0] image_selected_seen;
reg [26:0] osd_count;
reg osd_mode_adjust;
reg [18:0] subtitle_tick_count;
reg [8:0] subtitle_scroll_x;
wire frame_start = vs & ~vs_d;
wire line_start = de & ~de_d;
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
localparam [26:0] OSD_DISPLAY_CYCLES_VALUE = OSD_DISPLAY_CYCLES;

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
        // The legacy UART brightness gain is expressed in 1/64 units.
        // Saturation preserves the expected neutral value at gain=64 and
        // prevents bright scenes from wrapping around.
        product = component * level;
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

// Avoid a variable multiplier in the critical video path.  The fade effect
// is represented by the existing reveal mask; brightness remains adjustable.
wire [6:0] gain = brightness_gain(brightness_sync);
wire [23:0] faded_rgb = {
    scale_component(rgb_in[23:16], gain),
    scale_component(rgb_in[15:8], gain),
    scale_component(rgb_in[7:0], gain)
};
function [7:0] clamp8s;
    input signed [17:0] value;
    begin
        if (value < 0) clamp8s = 8'd0;
        else if (value > 255) clamp8s = 8'd255;
        else clamp8s = value[7:0];
    end
endfunction
function signed [17:0] contrast_apply;
    input signed [17:0] centered;
    input [6:0] level;
    reg [7:0] gain_q6;
    reg signed [26:0] product;
    begin
        // Q6 gain: 0=0.5x, 50=1.0x, 100=2.0x.  The controls only emit
        // five-point values, so the explicit 21-entry map avoids a divider
        // while retaining a visibly distinct linear response per key press.
        case (level)
            7'd0:gain_q6=8'd32;   7'd5:gain_q6=8'd35;
            7'd10:gain_q6=8'd38;  7'd15:gain_q6=8'd42;
            7'd20:gain_q6=8'd45;  7'd25:gain_q6=8'd48;
            7'd30:gain_q6=8'd51;  7'd35:gain_q6=8'd54;
            7'd40:gain_q6=8'd58;  7'd45:gain_q6=8'd61;
            7'd50:gain_q6=8'd64;  7'd55:gain_q6=8'd70;
            7'd60:gain_q6=8'd77;  7'd65:gain_q6=8'd83;
            7'd70:gain_q6=8'd90;  7'd75:gain_q6=8'd96;
            7'd80:gain_q6=8'd102; 7'd85:gain_q6=8'd109;
            7'd90:gain_q6=8'd115; 7'd95:gain_q6=8'd122;
            default:gain_q6=8'd128;
        endcase
        product = centered * $signed({1'b0,gain_q6});
        // Adding half an LSB before an arithmetic shift preserves exact
        // negative multiples of 64 as well as positive ones.
        contrast_apply = (product + 27'sd32) >>> 6;
    end
endfunction
function signed [9:0] brightness_offset;
    input [6:0] level;
    begin
        case (level)
            7'd0: brightness_offset=-10'sd128; 7'd5: brightness_offset=-10'sd115;
            7'd10: brightness_offset=-10'sd102; 7'd15: brightness_offset=-10'sd89;
            7'd20: brightness_offset=-10'sd77; 7'd25: brightness_offset=-10'sd64;
            7'd30: brightness_offset=-10'sd51; 7'd35: brightness_offset=-10'sd38;
            7'd40: brightness_offset=-10'sd26; 7'd45: brightness_offset=-10'sd13;
            7'd50: brightness_offset=10'sd0; 7'd55: brightness_offset=10'sd13;
            7'd60: brightness_offset=10'sd26; 7'd65: brightness_offset=10'sd38;
            7'd70: brightness_offset=10'sd51; 7'd75: brightness_offset=10'sd64;
            7'd80: brightness_offset=10'sd77; 7'd85: brightness_offset=10'sd89;
            7'd90: brightness_offset=10'sd102; 7'd95: brightness_offset=10'sd115;
            default: brightness_offset=10'sd128;
        endcase
    end
endfunction
function [7:0] image_adjust_component;
    input [7:0] component;
    input [6:0] brightness_level;
    input [6:0] contrast_level;
    reg signed [17:0] centered;
    reg signed [17:0] contrasted;
    reg signed [17:0] offset;
    begin
        centered = $signed({1'b0,component}) - 18'sd128;
        contrasted = contrast_apply(centered, contrast_level);
        offset = brightness_offset(brightness_level);
        image_adjust_component = clamp8s(contrasted + 18'sd128 + offset);
    end
endfunction
wire [23:0] adjusted_rgb = {
    image_adjust_component(faded_rgb[23:16], image_brightness_sync, image_contrast_sync),
    image_adjust_component(faded_rgb[15:8],  image_brightness_sync, image_contrast_sync),
    image_adjust_component(faded_rgb[7:0],   image_brightness_sync, image_contrast_sync)
};
// 水平单邻域锐化。Q6 强度在 0..100 的每个控制档位线性变化：
// 0 为 0.5 倍柔化，50 为原图，100 保持原先的 0.5 倍增强上限。
function [7:0] sharpen_component;
    input [7:0] current_component;
    input [7:0] previous_component;
    input [6:0] level;
    reg signed [9:0] current_signed;
    reg signed [9:0] previous_signed;
    reg signed [9:0] difference;
    reg signed [6:0] strength_q6;
    reg signed [17:0] product;
    reg signed [11:0] sharpened;
    begin
        current_signed = $signed({2'b00,current_component});
        previous_signed = $signed({2'b00,previous_component});
        difference = current_signed - previous_signed;
        case (level)
            7'd0:strength_q6=-7'sd32;   7'd5:strength_q6=-7'sd29;
            7'd10:strength_q6=-7'sd26;  7'd15:strength_q6=-7'sd22;
            7'd20:strength_q6=-7'sd19;  7'd25:strength_q6=-7'sd16;
            7'd30:strength_q6=-7'sd13;  7'd35:strength_q6=-7'sd10;
            7'd40:strength_q6=-7'sd6;   7'd45:strength_q6=-7'sd3;
            7'd50:strength_q6=7'sd0;    7'd55:strength_q6=7'sd3;
            7'd60:strength_q6=7'sd6;    7'd65:strength_q6=7'sd10;
            7'd70:strength_q6=7'sd13;   7'd75:strength_q6=7'sd16;
            7'd80:strength_q6=7'sd19;   7'd85:strength_q6=7'sd22;
            7'd90:strength_q6=7'sd26;   7'd95:strength_q6=7'sd29;
            default:strength_q6=7'sd32;
        endcase
        product = difference * strength_q6;
        sharpened = current_signed + ((product + 18'sd32) >>> 6);
        if (sharpened < 0)
            sharpen_component = 8'd0;
        else if (sharpened > 12'sd255)
            sharpen_component = 8'hff;
        else
            sharpen_component = sharpened[7:0];
    end
endfunction
wire show_osd = (osd_count != 27'd0);
wire [6:0] selected_value = (image_selected_sync == 2'd0) ? image_brightness_sync :
                             (image_selected_sync == 2'd1) ? image_contrast_sync : image_sharpness_sync;

// Small 5x7 parameter/status OSD.  It is deliberately independent of the
// subtitle font so that the top-left message can be changed without
// disturbing the scrolling caption.  A selection event shows only the
// parameter name; a key adjustment shows the numeric value and ADJUST.
function [4:0] param_font_row;
    input [7:0] ch; input [2:0] row;
    begin
        case (ch)
            "A": case(row) 0:param_font_row=5'b01110;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b11111;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b10001; endcase
            "B": case(row) 0:param_font_row=5'b11110;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b11110;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b11110; endcase
            "C": case(row) 0:param_font_row=5'b01111;1:param_font_row=5'b10000;2:param_font_row=5'b10000;3:param_font_row=5'b10000;4:param_font_row=5'b10000;5:param_font_row=5'b10000;default:param_font_row=5'b01111; endcase
            "D": case(row) 0:param_font_row=5'b11110;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b10001;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b11110; endcase
            "E": case(row) 0:param_font_row=5'b11111;1:param_font_row=5'b10000;2:param_font_row=5'b10000;3:param_font_row=5'b11110;4:param_font_row=5'b10000;5:param_font_row=5'b10000;default:param_font_row=5'b11111; endcase
            "G": case(row) 0:param_font_row=5'b01111;1:param_font_row=5'b10000;2:param_font_row=5'b10000;3:param_font_row=5'b10111;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b01110; endcase
            "H": case(row) 0:param_font_row=5'b10001;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b11111;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b10001; endcase
            "I": case(row) 0:param_font_row=5'b11111;1:param_font_row=5'b00100;2:param_font_row=5'b00100;3:param_font_row=5'b00100;4:param_font_row=5'b00100;5:param_font_row=5'b00100;default:param_font_row=5'b11111; endcase
            "J": case(row) 0:param_font_row=5'b00111;1:param_font_row=5'b00010;2:param_font_row=5'b00010;3:param_font_row=5'b00010;4:param_font_row=5'b00010;5:param_font_row=5'b10010;default:param_font_row=5'b01100; endcase
            "L": case(row) 0:param_font_row=5'b10000;1:param_font_row=5'b10000;2:param_font_row=5'b10000;3:param_font_row=5'b10000;4:param_font_row=5'b10000;5:param_font_row=5'b10000;default:param_font_row=5'b11111; endcase
            "N": case(row) 0:param_font_row=5'b10001;1:param_font_row=5'b11001;2:param_font_row=5'b10101;3:param_font_row=5'b10011;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b10001; endcase
            "O": case(row) 0:param_font_row=5'b01110;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b10001;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b01110; endcase
            "P": case(row) 0:param_font_row=5'b11110;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b11110;4:param_font_row=5'b10000;5:param_font_row=5'b10000;default:param_font_row=5'b10000; endcase
            "R": case(row) 0:param_font_row=5'b11110;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b11110;4:param_font_row=5'b10100;5:param_font_row=5'b10010;default:param_font_row=5'b10001; endcase
            "S": case(row) 0:param_font_row=5'b01111;1:param_font_row=5'b10000;2:param_font_row=5'b10000;3:param_font_row=5'b01110;4:param_font_row=5'b00001;5:param_font_row=5'b00001;default:param_font_row=5'b11110; endcase
            "T": case(row) 0:param_font_row=5'b11111;1:param_font_row=5'b00100;2:param_font_row=5'b00100;3:param_font_row=5'b00100;4:param_font_row=5'b00100;5:param_font_row=5'b00100;default:param_font_row=5'b00100; endcase
            "U": case(row) 0:param_font_row=5'b10001;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b10001;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b01110; endcase
            8'h30: param_font_row = (row==0 || row==6) ? 5'b01110 : 5'b10001;
            8'h31: param_font_row = (row==0) ? 5'b00100 : 5'b01100;
            8'h32: case(row) 0:param_font_row=5'b01110;1:param_font_row=5'b10001;2:param_font_row=5'b00001;3:param_font_row=5'b00110;4:param_font_row=5'b01000;5:param_font_row=5'b10000;default:param_font_row=5'b11111; endcase
            8'h33: case(row) 0:param_font_row=5'b11110;1:param_font_row=5'b00001;2:param_font_row=5'b00001;3:param_font_row=5'b01110;4:param_font_row=5'b00001;5:param_font_row=5'b00001;default:param_font_row=5'b11110; endcase
            8'h34: case(row) 0:param_font_row=5'b00010;1:param_font_row=5'b00110;2:param_font_row=5'b01010;3:param_font_row=5'b10010;4:param_font_row=5'b11111;5:param_font_row=5'b00010;default:param_font_row=5'b00010; endcase
            8'h35: case(row) 0:param_font_row=5'b11111;1:param_font_row=5'b10000;2:param_font_row=5'b10000;3:param_font_row=5'b11110;4:param_font_row=5'b00001;5:param_font_row=5'b00001;default:param_font_row=5'b11110; endcase
            8'h36: case(row) 0:param_font_row=5'b00110;1:param_font_row=5'b01000;2:param_font_row=5'b10000;3:param_font_row=5'b11110;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b01110; endcase
            8'h37: case(row) 0:param_font_row=5'b11111;1:param_font_row=5'b00001;2:param_font_row=5'b00010;3:param_font_row=5'b00100;4:param_font_row=5'b01000;5:param_font_row=5'b01000;default:param_font_row=5'b01000; endcase
            8'h38: case(row) 0:param_font_row=5'b01110;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b01110;4:param_font_row=5'b10001;5:param_font_row=5'b10001;default:param_font_row=5'b01110; endcase
            8'h39: case(row) 0:param_font_row=5'b01110;1:param_font_row=5'b10001;2:param_font_row=5'b10001;3:param_font_row=5'b01111;4:param_font_row=5'b00001;5:param_font_row=5'b00010;default:param_font_row=5'b11100; endcase
            default: param_font_row = 5'b00000;
        endcase
    end
endfunction
function [7:0] parameter_char;
    input [1:0] which; input [3:0] index;
    begin
        if (which==2'd0) begin case(index) 0:parameter_char="B";1:parameter_char="R";2:parameter_char="I";3:parameter_char="G";4:parameter_char="H";5:parameter_char="T";6:parameter_char="N";7:parameter_char="E";8:parameter_char="S";9:parameter_char="S";default:parameter_char=" "; endcase end
        else if (which==2'd1) begin case(index) 0:parameter_char="C";1:parameter_char="O";2:parameter_char="N";3:parameter_char="T";4:parameter_char="R";5:parameter_char="A";6:parameter_char="S";7:parameter_char="T";default:parameter_char=" "; endcase end
        else begin case(index) 0:parameter_char="S";1:parameter_char="H";2:parameter_char="A";3:parameter_char="R";4:parameter_char="P";5:parameter_char="N";6:parameter_char="E";7:parameter_char="S";8:parameter_char="S";default:parameter_char=" "; endcase end
    end
endfunction
wire [3:0] osd_hundreds = image_value_seen / 7'd100;
wire [3:0] osd_tens = (image_value_seen / 7'd10) % 7'd10;
wire [3:0] osd_ones = image_value_seen % 7'd10;
function [4:0] parameter_name_length;
    input [1:0] which;
    begin
        case (which)
            2'd0: parameter_name_length = 5'd10; // BRIGHTNESS
            2'd1: parameter_name_length = 5'd8;  // CONTRAST
            default: parameter_name_length = 5'd9; // SHARPNESS
        endcase
    end
endfunction
wire [4:0] parameter_value_length = (image_value_seen >= 7'd100) ? 5'd3 :
                                    (image_value_seen >= 7'd10)  ? 5'd2 : 5'd1;
wire [4:0] parameter_osd_length = osd_mode_adjust ? parameter_value_length :
                                  parameter_name_length(image_selected_seen);
function [7:0] parameter_osd_char;
    input [4:0] idx;
    begin
        if (!osd_mode_adjust) begin
            if (idx < parameter_name_length(image_selected_seen))
                parameter_osd_char = parameter_char(image_selected_seen, idx[3:0]);
            else
                parameter_osd_char = " ";
        end else if (image_value_seen >= 7'd100) begin
            case (idx)
                0: parameter_osd_char = 8'h30 + osd_hundreds;
                1: parameter_osd_char = 8'h30 + osd_tens;
                2: parameter_osd_char = 8'h30 + osd_ones;
                default: parameter_osd_char = " ";
            endcase
        end else if (image_value_seen >= 7'd10) begin
            case (idx)
                0: parameter_osd_char = 8'h30 + osd_tens;
                1: parameter_osd_char = 8'h30 + osd_ones;
                default: parameter_osd_char = " ";
            endcase
        end else begin
            parameter_osd_char = (idx == 0) ? (8'h30 + osd_ones) : " ";
        end
    end
endfunction
wire param_osd_area = show_osd && (pixel_y >= 10'd2) && (pixel_y < 10'd10) &&
                      (render_x >= 10'd8) &&
                      (render_x < (10'd8 + {2'd0, parameter_osd_length, 3'd0}));
wire [9:0] param_osd_rel_x = (render_x >= 10'd8) ? render_x - 10'd8 : 10'd0;
wire [4:0] param_osd_index = param_osd_rel_x[9:3];
wire [2:0] param_osd_col = param_osd_rel_x[2:0];
wire [2:0] param_osd_row = pixel_y - 10'd2;
wire [4:0] param_osd_glyph_row = param_font_row(parameter_osd_char(param_osd_index), param_osd_row);
wire param_osd_pixel = param_osd_area && (param_osd_col < 3'd5) &&
                       param_osd_glyph_row[4-param_osd_col];

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
    (adjusted_rgb[23:16] >> 1) + (adjusted_rgb[23:16] >> 2),
    (adjusted_rgb[15:8]  >> 1) + (adjusted_rgb[15:8]  >> 2),
    (adjusted_rgb[7:0]   >> 1) + (adjusted_rgb[7:0]   >> 2)
};

// 第一级锁存图像调节结果及同像素的叠加判定；第二级锁存
// 锐化/叠加结果。顶层必须将 DE/VS 同样延迟两拍。
reg [23:0] adjusted_rgb_stage;
reg [23:0] previous_adjusted_rgb;
reg [23:0] banner_rgb_stage;
reg [23:0] spectrum_rgb_stage;
reg [6:0] sharpness_stage;
reg base_valid_stage;
reg line_first_stage;
reg param_osd_stage;
reg spectrum_stage;
reg subtitle_text_stage;
reg subtitle_banner_stage;
wire [23:0] sharpened_rgb_stage = line_first_stage ? adjusted_rgb_stage : {
    sharpen_component(adjusted_rgb_stage[23:16], previous_adjusted_rgb[23:16], sharpness_stage),
    sharpen_component(adjusted_rgb_stage[15:8],  previous_adjusted_rgb[15:8],  sharpness_stage),
    sharpen_component(adjusted_rgb_stage[7:0],   previous_adjusted_rgb[7:0],   sharpness_stage)
};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        slot_sync0 <= 2'd0; slot_sync1 <= 2'd0; active_slot <= 2'd0;
        display_valid_meta <= 1'b0; display_valid_sync <= 1'b0;
        display_switch_toggle_meta <= 1'b0;
        display_switch_toggle_sync <= 1'b0;
        display_switch_toggle_seen <= 1'b0;
        display_slot_applied_toggle <= 1'b0;
        vs_d <= 1'b0; de_d <= 1'b0; pixel_x <= 10'd0; pixel_y <= 10'd0;
        reveal_x <= ACTIVE_WIDTH; fade_level <= 7'd64;
        brightness_meta <= 3'd4; brightness_sync <= 3'd4;
        image_brightness_meta<=7'd50; image_brightness_sync<=7'd50;
        image_contrast_meta<=7'd50; image_contrast_sync<=7'd50;
        image_sharpness_meta<=7'd50; image_sharpness_sync<=7'd50;
        image_selected_meta<=2'd0; image_selected_sync<=2'd0;
        image_select_toggle_meta<=0; image_select_toggle_sync<=0; image_select_toggle_seen<=0;
        image_adjust_toggle_meta<=0; image_adjust_toggle_sync<=0; image_adjust_toggle_seen<=0;
        image_value_seen<=7'd50; image_selected_seen<=2'd0;
        osd_mode_adjust<=1'b0;
        spectrum_meta <= 64'd0; spectrum_sync <= 64'd0;
        osd_count <= 27'd0;
        subtitle_tick_count <= 19'd0;
        subtitle_scroll_x <= 9'd0;
        adjusted_rgb_stage <= 24'd0; previous_adjusted_rgb <= 24'd0;
        banner_rgb_stage <= 24'd0; spectrum_rgb_stage <= 24'd0;
        sharpness_stage <= 7'd50; base_valid_stage <= 1'b0;
        line_first_stage <= 1'b0; param_osd_stage <= 1'b0;
        spectrum_stage <= 1'b0; subtitle_text_stage <= 1'b0;
        subtitle_banner_stage <= 1'b0;
        rgb_out <= 24'd0;
    end else begin
        slot_sync0 <= display_slot_async; slot_sync1 <= slot_sync0;
        display_switch_toggle_meta <= display_switch_toggle_async;
        display_switch_toggle_sync <= display_switch_toggle_meta;
        display_valid_meta <= display_valid; display_valid_sync <= display_valid_meta;
        brightness_meta <= brightness_level_async; brightness_sync <= brightness_meta;
        image_brightness_meta <= image_brightness_async; image_brightness_sync <= image_brightness_meta;
        image_contrast_meta <= image_contrast_async; image_contrast_sync <= image_contrast_meta;
        image_sharpness_meta <= image_sharpness_async; image_sharpness_sync <= image_sharpness_meta;
        image_selected_meta <= image_selected_async; image_selected_sync <= image_selected_meta;
        image_select_toggle_meta <= image_select_toggle_async; image_select_toggle_sync <= image_select_toggle_meta;
        image_adjust_toggle_meta <= image_adjust_toggle_async; image_adjust_toggle_sync <= image_adjust_toggle_meta;
        spectrum_meta <= spectrum_bands; spectrum_sync <= spectrum_meta;
        if (image_adjust_toggle_sync != image_adjust_toggle_seen) begin
            image_adjust_toggle_seen <= image_adjust_toggle_sync;
            image_value_seen <= selected_value;
            image_selected_seen <= image_selected_sync;
            osd_mode_adjust <= 1'b1;
            // 默认 25 MHz 视频时钟下显示 2 s；参数允许仿真缩短。
            osd_count <= OSD_DISPLAY_CYCLES_VALUE;
        end else if (image_select_toggle_sync != image_select_toggle_seen) begin
            image_select_toggle_seen <= image_select_toggle_sync;
            image_selected_seen <= image_selected_sync;
            osd_mode_adjust <= 1'b0;
            osd_count <= OSD_DISPLAY_CYCLES_VALUE;
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
            if (display_switch_toggle_sync != display_switch_toggle_seen) begin
                // The slot bus is held until this acknowledgement crosses
                // back to the SD domain.  Apply it only on a frame boundary
                // so every queued selection is visibly presented.
                active_slot <= slot_sync1;
                display_switch_toggle_seen <= display_switch_toggle_sync;
                display_slot_applied_toggle <= ~display_slot_applied_toggle;
                reveal_x <= 10'd0;
                fade_level <= 7'd8;
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
        // 第一级：将当前输入像素及所有叠加判定锁存。
        adjusted_rgb_stage <= adjusted_rgb;
        banner_rgb_stage <= subtitle_banner_rgb;
        spectrum_rgb_stage <= spectrum_rgb;
        sharpness_stage <= image_sharpness_sync;
        base_valid_stage <= display_valid_sync && de && (render_x < reveal_x);
        line_first_stage <= line_start;
        param_osd_stage <= param_osd_pixel;
        spectrum_stage <= spectrum_on;
        subtitle_text_stage <= subtitle_text_pixel;
        subtitle_banner_stage <= subtitle_banner_area;

        // 左邻像素只在有效行内推进；消隐期清零，防止跨行引用。
        if (!de)
            previous_adjusted_rgb <= 24'd0;
        else if (base_valid_stage)
            previous_adjusted_rgb <= adjusted_rgb_stage;

        // 第二级：OSD/频谱/字幕保持高于图像锐化的优先级。
        if (!base_valid_stage) rgb_out <= 24'd0;
        else if (param_osd_stage) rgb_out <= 24'h000000;
        else if (spectrum_stage) rgb_out <= spectrum_rgb_stage;
        else if (subtitle_text_stage) rgb_out <= 24'hFFE040;
        else if (subtitle_banner_stage) rgb_out <= banner_rgb_stage;
        else rgb_out <= sharpened_rgb_stage;
    end
end
endmodule
