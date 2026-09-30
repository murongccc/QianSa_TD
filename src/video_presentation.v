// 视频呈现：图像参数处理、环形音频频谱及左上角参数 OSD。
module video_presentation #(
    parameter integer ACTIVE_WIDTH = 640,
    parameter integer REFERENCE_SPECTRUM = 0,
    parameter integer ACTIVE_HEIGHT = 480,
    parameter integer OSD_DISPLAY_CYCLES = 50_000_000,
    // 首次显示前等待帧读通路稳定；运行中切图不增加这段等待。
    parameter integer INITIAL_WARMUP_FRAMES = 8
)(
    input wire clk, input wire rst, input wire display_valid,
    input wire [2:0] display_slot_async,
    input wire display_switch_toggle_async,
    output reg display_slot_applied_toggle,
    output reg display_active,
    input wire [2:0] brightness_level_async,
    input wire [6:0] image_brightness_async,
    input wire [6:0] image_contrast_async,
    input wire [6:0] image_sharpness_async,
    input wire [1:0] image_selected_async,
    input wire image_select_toggle_async,
    input wire image_adjust_toggle_async,
    input wire [255:0] spectrum_bands,
    input wire [639:0] spectrum_bars,
    input wire [7:0] spectrum_radius,
    input wire de, input wire vs, input wire [23:0] rgb_in,
    output reg [23:0] rgb_out
);
reg [2:0] slot_sync0, slot_sync1, active_slot;
reg display_switch_toggle_meta, display_switch_toggle_sync;
reg display_switch_toggle_seen;
reg vs_d, de_d;
reg display_valid_meta, display_valid_sync;
reg [3:0] initial_warmup_frames;
reg [9:0] pixel_x, pixel_y, reveal_x;
reg [6:0] fade_level;
reg [2:0] brightness_meta, brightness_sync;
reg [6:0] image_brightness_meta, image_brightness_sync;
reg [6:0] image_contrast_meta, image_contrast_sync;
reg [1:0] image_selected_meta, image_selected_sync;
reg image_select_toggle_meta, image_select_toggle_sync, image_select_toggle_seen;
reg image_adjust_toggle_meta, image_adjust_toggle_sync, image_adjust_toggle_seen;
reg [6:0] image_value_seen;
reg [1:0] image_selected_seen;
reg [26:0] osd_count;
reg osd_mode_adjust;
wire frame_start = vs & ~vs_d;
wire line_start = de & ~de_d;
// pixel_x is updated on the clock edge.  At the first active pixel of every
// line it still contains the previous line's terminal value (640), so use an
// explicit zero coordinate for that cycle.  Otherwise the reveal mask treats
// the leftmost column as out of range after a slide transition.
wire [9:0] render_x = line_start ? 10'd0 : pixel_x;

localparam [26:0] OSD_DISPLAY_CYCLES_VALUE = OSD_DISPLAY_CYCLES;
localparam [3:0] INITIAL_WARMUP_FRAMES_VALUE = INITIAL_WARMUP_FRAMES;

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
wire show_osd = (osd_count != 27'd0);
wire [6:0] selected_value = (image_selected_sync == 2'd0) ? image_brightness_sync :
                             image_contrast_sync;

// 左上角 5x7 参数 OSD：选择时显示参数名称，调整时显示数值。
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
        else parameter_char=" ";
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
            default: parameter_name_length = 5'd0; // 保留组合不显示参数名称
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

wire spectrum_on;
wire [23:0] spectrum_rgb;
ring_spectrum_renderer #(
    .REFERENCE_MODE(REFERENCE_SPECTRUM),
    .ACTIVE_WIDTH(ACTIVE_WIDTH), .ACTIVE_HEIGHT(ACTIVE_HEIGHT)
) u_ring_spectrum_renderer (
    .clk(clk), .rst(rst), .breath_radius(spectrum_radius),
    .bars(spectrum_bars), .pixel_x(render_x), .pixel_y(pixel_y), .bands(spectrum_bands),
    .pixel_on(spectrum_on), .pixel_rgb(spectrum_rgb)
);

// 频谱模块内部完成同像素的第一级锁存；本模块第一级锁存其他叠加判定。
// 第二级锁存图像/叠加结果。顶层必须将 DE/VS 同样延迟两拍。
reg [23:0] adjusted_rgb_stage;
reg base_valid_stage;
reg param_osd_stage;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        slot_sync0 <= 2'd0; slot_sync1 <= 2'd0; active_slot <= 2'd0;
        display_valid_meta <= 1'b0; display_valid_sync <= 1'b0;
        display_active <= 1'b0; initial_warmup_frames <= 4'd0;
        display_switch_toggle_meta <= 1'b0;
        display_switch_toggle_sync <= 1'b0;
        display_switch_toggle_seen <= 1'b0;
        display_slot_applied_toggle <= 1'b0;
        vs_d <= 1'b0; de_d <= 1'b0; pixel_x <= 10'd0; pixel_y <= 10'd0;
        reveal_x <= ACTIVE_WIDTH; fade_level <= 7'd64;
        brightness_meta <= 3'd4; brightness_sync <= 3'd4;
        image_brightness_meta<=7'd50; image_brightness_sync<=7'd50;
        image_contrast_meta<=7'd50; image_contrast_sync<=7'd50;
        image_selected_meta<=2'd0; image_selected_sync<=2'd0;
        image_select_toggle_meta<=0; image_select_toggle_sync<=0; image_select_toggle_seen<=0;
        image_adjust_toggle_meta<=0; image_adjust_toggle_sync<=0; image_adjust_toggle_seen<=0;
        image_value_seen<=7'd50; image_selected_seen<=2'd0;
        osd_mode_adjust<=1'b0;
        osd_count <= 27'd0;
        adjusted_rgb_stage <= 24'd0;
        base_valid_stage <= 1'b0;
        param_osd_stage <= 1'b0;
        rgb_out <= 24'd0;
    end else begin
        slot_sync0 <= display_slot_async; slot_sync1 <= slot_sync0;
        display_switch_toggle_meta <= display_switch_toggle_async;
        display_switch_toggle_sync <= display_switch_toggle_meta;
        display_valid_meta <= display_valid; display_valid_sync <= display_valid_meta;
        brightness_meta <= brightness_level_async; brightness_sync <= brightness_meta;
        image_brightness_meta <= image_brightness_async; image_brightness_sync <= image_brightness_meta;
        image_contrast_meta <= image_contrast_async; image_contrast_sync <= image_contrast_meta;
        image_selected_meta <= image_selected_async; image_selected_sync <= image_selected_meta;
        image_select_toggle_meta <= image_select_toggle_async; image_select_toggle_sync <= image_select_toggle_meta;
        image_adjust_toggle_meta <= image_adjust_toggle_async; image_adjust_toggle_sync <= image_adjust_toggle_meta;
        if ((image_adjust_toggle_sync != image_adjust_toggle_seen) && (image_selected_sync < 2'd2)) begin
            image_adjust_toggle_seen <= image_adjust_toggle_sync;
            image_value_seen <= selected_value;
            image_selected_seen <= image_selected_sync;
            osd_mode_adjust <= 1'b1;
            // 默认 25 MHz 视频时钟下显示 2 s；参数允许仿真缩短。
            osd_count <= OSD_DISPLAY_CYCLES_VALUE;
        end else if ((image_select_toggle_sync != image_select_toggle_seen) && (image_selected_sync < 2'd2)) begin
            image_select_toggle_seen <= image_select_toggle_sync;
            image_selected_seen <= image_selected_sync;
            osd_mode_adjust <= 1'b0;
            osd_count <= OSD_DISPLAY_CYCLES_VALUE;
        end else if (osd_count != 27'd0) begin
            osd_count <= osd_count - 27'd1;
        end
        vs_d <= vs; de_d <= de;
        if (frame_start) begin
            pixel_y <= 10'd0;
            // 首槽已在帧边界选定后，display_valid 才从 SD 域返回。先让
            // SDRAM 读通路和 FIFO 经过完整帧预热，避免在该帧中途放开 RGB；
            // 仅在当前视频帧边界显示首图。display_active 置位后保持到
            // 复位，因此手动切图和自动轮播不增加启动等待。
            if (!display_active && display_valid_sync) begin
                if (initial_warmup_frames == INITIAL_WARMUP_FRAMES_VALUE)
                    display_active <= 1'b1;
                else
                    initial_warmup_frames <= initial_warmup_frames + 1'b1;
            end
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
        base_valid_stage <= display_active && de && (render_x < reveal_x);
        param_osd_stage <= param_osd_pixel;

        // 第二级：参数 OSD/频谱优先于处理后的底图。
        if (!base_valid_stage) rgb_out <= 24'd0;
        else if (param_osd_stage) rgb_out <= 24'h000000;
        else if (spectrum_on) rgb_out <= spectrum_rgb;
        else rgb_out <= adjusted_rgb_stage;
    end
end
endmodule
