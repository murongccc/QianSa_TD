// 视频呈现：图像参数处理、环形音频频谱及右侧中文图片信息栏。
module video_presentation #(
    parameter integer ACTIVE_WIDTH = 640,
    parameter integer REFERENCE_SPECTRUM = 0,
    parameter integer ACTIVE_HEIGHT = 480,
    // 首次显示前等待帧读通路稳定；运行中切图不增加这段等待。
    parameter integer INITIAL_WARMUP_FRAMES = 8, parameter integer ENABLE_RHYTHM = 0,
    parameter integer BLOCK_BARS = 0,
    parameter integer ENABLE_TOUCH_MARKERS = 0
)(
    input wire clk, input wire rst, input wire display_valid,
    input wire [2:0] display_slot_async,
    input wire [88:0] display_info,
    output wire info_frame_start,output wire [2:0] info_slot,
    input wire display_switch_toggle_async,
    output reg display_slot_applied_toggle,
    output reg display_active,
    input wire [6:0] image_brightness_async,
    input wire [6:0] image_contrast_async,
    input wire [6:0] image_sharpness_async,
    input wire [1:0] image_selected_async,
    input wire [255:0] spectrum_bands,
    input wire [639:0] spectrum_bars,
    input wire [7:0] spectrum_radius,
    output wire [6:0] spectrum_read_address,
    input wire [7:0] spectrum_read_data,
    input wire spectrum_read_valid, input wire spectrum_active,
    input wire game_active,game_pixel_on,game_pixel_light,input wire [23:0] game_pixel_rgb,
    input wire [39:0] touch_frame_packet,
    input wire de, input wire vs, input wire [23:0] rgb_in,
    output reg [23:0] rgb_out
);
reg [2:0] slot_sync0, slot_sync1, active_slot;
// 元数据由双时钟BRAM在本域消隐期间组包，不再逐位同步宽总线。
wire [88:0] active_info=display_info;
reg display_switch_toggle_meta, display_switch_toggle_sync;
reg display_switch_toggle_seen;
reg vs_d, de_d;
reg display_valid_meta, display_valid_sync;
reg [3:0] initial_warmup_frames;
reg [9:0] pixel_x, pixel_y, reveal_x;
reg [6:0] fade_level;
reg [6:0] image_brightness_meta, image_brightness_sync;
reg [6:0] image_contrast_meta, image_contrast_sync;
reg [1:0] image_selected_meta, image_selected_sync;
wire frame_start = vs & ~vs_d;
assign info_frame_start=frame_start;
assign info_slot=(display_switch_toggle_sync!=display_switch_toggle_seen) ? slot_sync1 : active_slot;
wire line_start = de & ~de_d;
// 消隐开始时已把横坐标清零，下一行首个有效像素直接使用寄存值 0。
// 避免 de 经首像素选择器进入频谱环的深层几何组合路径。
wire [9:0] render_x = pixel_x;

localparam [3:0] INITIAL_WARMUP_FRAMES_VALUE = INITIAL_WARMUP_FRAMES;

// 移除串口亮度倍率后，原始RGB以1.0倍直接进入亮度/对比度处理。
wire [23:0] faded_rgb=rgb_in;
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
wire spectrum_on;
wire [23:0] spectrum_rgb;
// 稳定会话状态仅在帧边界切换频谱位置和背景压暗。
reg game_frame_mode;
reg [8:0] touch_y;
// 游戏使用与轨道一致的行末计数；普通模式沿用原频谱扫描坐标。
wire [9:0] spectrum_y=game_frame_mode ? {1'b0,touch_y} : pixel_y;
ring_spectrum_renderer #(
    .ENABLE_GAME_LAYOUT(ENABLE_RHYTHM),
    .REFERENCE_MODE(REFERENCE_SPECTRUM),
    .BLOCK_BARS(BLOCK_BARS),
    .ACTIVE_WIDTH(ACTIVE_WIDTH), .ACTIVE_HEIGHT(ACTIVE_HEIGHT)
) u_ring_spectrum_renderer (
    .clk(clk), .rst(rst), .breath_radius(spectrum_radius),
    .bars(spectrum_bars), .pixel_x(render_x), .pixel_y(spectrum_y), .bands(spectrum_bands),
    .bars_read_address(spectrum_read_address),.bars_read_data(spectrum_read_data),
    .bars_read_valid(spectrum_read_valid),.bars_active(spectrum_active),
    .game_layout(game_frame_mode),
    .pixel_on(spectrum_on), .pixel_rgb(spectrum_rgb)
);

// 频谱模块内部完成同像素的第一级锁存；本模块第一级锁存其他叠加判定。
// 第二级锁存图像/叠加结果。顶层必须将 DE/VS 同样延迟两拍。
reg [23:0] adjusted_rgb_stage;
reg base_valid_stage;
wire info_panel_stage,info_ink_stage;
wire [23:0] info_ink_rgb;
generate if(ACTIVE_WIDTH>=240 && ACTIVE_HEIGHT>=176)begin : g_image_info
    image_info_osd #(.ACTIVE_WIDTH(ACTIVE_WIDTH),.ACTIVE_HEIGHT(ACTIVE_HEIGHT)) u_osd(
        .clk(clk),.rst(rst),.frame_start(frame_start),
        .enable(display_active && active_info[88] && !game_frame_mode),.de(de),
        .pixel_x(render_x),.pixel_y({1'b0,touch_y}),.image_info(active_info[87:0]),
        .brightness(image_brightness_sync),.contrast(image_contrast_sync),.selected(image_selected_sync),
        .panel_on(info_panel_stage),.ink_on(info_ink_stage),.ink_rgb(info_ink_rgb));
end else begin : g_without_image_info
    assign info_panel_stage=1'b0;assign info_ink_stage=1'b0;assign info_ink_rgb=24'd0;
end endgenerate
reg game_stage;
reg touch_a_stage,touch_b_stage;
wire touch_a_hit,touch_b_hit;
generate if(ENABLE_TOUCH_MARKERS)begin : g_touch_markers
    touch_marker u_marker(.active(de),.pixel_x(render_x),.pixel_y({1'b0,touch_y}),
        .frame_packet(touch_frame_packet),.a_hit(touch_a_hit),.b_hit(touch_b_hit));
end else begin : g_without_touch_markers
    assign touch_a_hit=1'b0;
    assign touch_b_hit=1'b0;
end endgenerate
// 背景压暗由稳定会话状态在帧边界选择，不随渲染器清理/等待快照而关闭。
// 游戏底图增益5/16（31.25%），原为1/4；常量移位加法，不新增DSP或流水拍。
function [7:0] game_background_component;
    input [7:0] component;
    reg [10:0] scaled;
    begin
        scaled={1'b0,component,2'b00}+{3'b000,component};
        game_background_component={1'b0,scaled[10:4]};
    end
endfunction
wire [23:0] dimmed_rgb={game_background_component(adjusted_rgb_stage[23:16]),
    game_background_component(adjusted_rgb_stage[15:8]),game_background_component(adjusted_rgb_stage[7:0])};
// 位或式提亮：各通道不低于原背景；无加法溢出或透明度乘法，避免深色矩形覆盖。
// 共用三通道背景使能，避免每个颜色位重复展开on/light/base_valid选择。
// 频谱和游戏像素均已锁存一级，合成保持既有两拍延迟。
wire [23:0] game_backdrop_rgb=spectrum_on ? spectrum_rgb : (dimmed_rgb & {24{base_valid_stage}});
wire game_background_enable=!game_pixel_on || game_pixel_light;
wire [23:0] game_layer_rgb=(game_pixel_rgb & {24{game_pixel_on}}) |
    (game_backdrop_rgb & {24{game_background_enable}});

// 底板在最终图片/频谱上压暗一半，文字不经过图片参数调节。
wire [23:0] info_underlay=(spectrum_on ? spectrum_rgb : adjusted_rgb_stage) & {24{base_valid_stage}};
wire [23:0] info_background_rgb={1'b0,info_underlay[23:17],1'b0,info_underlay[15:9],1'b0,info_underlay[7:1]};
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
        image_brightness_meta<=7'd50; image_brightness_sync<=7'd50;
        image_contrast_meta<=7'd50; image_contrast_sync<=7'd50;
        image_selected_meta<=2'd0; image_selected_sync<=2'd0;
        adjusted_rgb_stage <= 24'd0;
        base_valid_stage <= 1'b0;
        game_stage<=0;game_frame_mode<=0;
        touch_a_stage<=1'b0;touch_b_stage<=1'b0;touch_y<=9'd0;
        rgb_out <= 24'd0;
    end else begin
        slot_sync0 <= display_slot_async; slot_sync1 <= slot_sync0;
        display_switch_toggle_meta <= display_switch_toggle_async;
        display_switch_toggle_sync <= display_switch_toggle_meta;
        display_valid_meta <= display_valid; display_valid_sync <= display_valid_meta;
        image_brightness_meta <= image_brightness_async; image_brightness_sync <= image_brightness_meta;
        image_contrast_meta <= image_contrast_async; image_contrast_sync <= image_contrast_meta;
        image_selected_meta <= image_selected_async; image_selected_sync <= image_selected_meta;
        vs_d <= vs; de_d <= de;
        // 十字使用准确的当前行号：行结束再递增，首行/末行均与 DE 对齐。
        if(frame_start)touch_y<=9'd0;
        else if(de_d && !de && touch_y<ACTIVE_HEIGHT-1)touch_y<=touch_y+9'd1;
        if (frame_start) begin
            game_frame_mode<=ENABLE_RHYTHM && game_active;
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
            if (pixel_y < ACTIVE_HEIGHT - 1) pixel_y <= pixel_y + 10'd1;
        end
        if (de_d && !de) pixel_x <= 10'd0;
        else if (de) pixel_x <= pixel_x + 10'd1;
        // 第一级：将当前输入像素及所有叠加判定锁存。
        adjusted_rgb_stage <= adjusted_rgb;
        base_valid_stage <= display_active && de && (render_x < reveal_x);
        game_stage<=game_frame_mode;
        touch_a_stage<=touch_a_hit;touch_b_stage<=touch_b_hit;

        // 第二级：游戏HUD/音符覆盖频谱，光晕提亮频谱或压暗底图。
        // A青色、B品红色、重合白色；同样经过两拍，优先于 OSD/频谱/游戏。
        if(touch_a_stage || touch_b_stage)rgb_out<={{8{touch_b_stage}},{8{touch_a_stage}},8'hff};
        else if(game_stage)rgb_out<=game_layer_rgb;
        else if(info_panel_stage)rgb_out<=info_ink_stage ? info_ink_rgb : info_background_rgb;
        else if (!base_valid_stage) rgb_out <= 24'd0;
        else if (spectrum_on) rgb_out <= spectrum_rgb;
        else rgb_out <= adjusted_rgb_stage;
    end
end
endmodule
