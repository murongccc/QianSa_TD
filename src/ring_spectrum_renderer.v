// 参考模式直接显示 80 柱；兼容模式保留 32 段重采样。
// 起点位于右侧，频率顺时针增加；兼容模式保留旧首尾渐变，参考模式直接取柱。
module ring_spectrum_renderer #(
    parameter integer ACTIVE_WIDTH = 640,
    parameter integer REFERENCE_MODE = 0,
    parameter integer ACTIVE_HEIGHT = 480
)(
    input wire clk,
    input wire rst,
    input wire frame_start,
    input wire [9:0] pixel_x,
    input wire [9:0] pixel_y,
    input wire [255:0] bands,
    input wire [639:0] bars,
    output wire pixel_on,
    output wire [23:0] pixel_rgb
);
localparam [9:0] CENTER_X = ACTIVE_WIDTH / 2;
localparam [9:0] CENTER_Y = ACTIVE_HEIGHT / 2;
wire [10:0] abs_x = (pixel_x >= CENTER_X) ?
    ({1'b0,pixel_x} - {1'b0,CENTER_X}) : ({1'b0,CENTER_X} - {1'b0,pixel_x});
wire [10:0] abs_y = (pixel_y >= CENTER_Y) ?
    ({1'b0,pixel_y} - {1'b0,CENTER_Y}) : ({1'b0,CENTER_Y} - {1'b0,pixel_y});
wire x_right = pixel_x >= CENTER_X;
wire y_down = pixel_y >= CENTER_Y;
wire in_circle_bounds = (abs_x <= 11'd176) && (abs_y <= 11'd176);
// 参考项目按峰值平滑后做 3*log2(M+1) 的半径扩张。
// 当前柱等级 P 约为 100*ln(1+0.1*M)，以下阈值近似反推 M 后的整数扩张。
function [4:0] radius_offset;
    input [7:0] peak;
    begin
        if      (peak >= 8'd241) radius_offset=5'd20;
        else if (peak >= 8'd220) radius_offset=5'd19;
        else if (peak >= 8'd199) radius_offset=5'd18;
        else if (peak >= 8'd179) radius_offset=5'd17;
        else if (peak >= 8'd160) radius_offset=5'd16;
        else if (peak >= 8'd142) radius_offset=5'd15;
        else if (peak >= 8'd124) radius_offset=5'd14;
        else if (peak >= 8'd108) radius_offset=5'd13;
        else if (peak >= 8'd92)  radius_offset=5'd12;
        else if (peak >= 8'd78)  radius_offset=5'd11;
        else if (peak >= 8'd65)  radius_offset=5'd10;
        else if (peak >= 8'd54)  radius_offset=5'd9;
        else if (peak >= 8'd43)  radius_offset=5'd8;
        else if (peak >= 8'd34)  radius_offset=5'd7;
        else if (peak >= 8'd27)  radius_offset=5'd6;
        else if (peak >= 8'd20)  radius_offset=5'd5;
        else if (peak >= 8'd15)  radius_offset=5'd4;
        else if (peak >= 8'd10)  radius_offset=5'd3;
        else if (peak >= 8'd6)   radius_offset=5'd2;
        else if (peak >= 8'd3)   radius_offset=5'd1;
        else radius_offset=5'd0;
    end
endfunction
wire [7:0] base_radius;
wire [16:0] base_radius_sq;
generate if (REFERENCE_MODE) begin : g_breath
    reg frame_start_d, scan_busy, peak_ready;
    reg [6:0] scan_index;
    reg [7:0] scan_peak, pending_peak, peak_envelope, radius;
    wire [7:0] scan_level=bars[scan_index*8 +:8];
    wire [7:0] next_peak=(scan_level>scan_peak)?scan_level:scan_peak;
    // 13/16 新值 + 3/16 历史值，约为参考的 0.8/0.2；移位加法不用 DSP。
    wire [11:0] peak_wide={4'd0,pending_peak};
    wire [11:0] history_wide={4'd0,peak_envelope};
    wire [11:0] envelope_sum=(peak_wide<<3)+(peak_wide<<2)+peak_wide+
                              (history_wide<<1)+history_wide+12'd8;
    wire [7:0] next_envelope=envelope_sum[11:4];
    assign base_radius=radius;
    // 小范围查表代替新增半径平方乘法器，避免占用额外 DSP。
    reg [16:0] radius_square;
    always @* begin
        case(radius)
            8'd91: radius_square=17'd8281;
            8'd92: radius_square=17'd8464;
            8'd93: radius_square=17'd8649;
            8'd94: radius_square=17'd8836;
            8'd95: radius_square=17'd9025;
            8'd96: radius_square=17'd9216;
            8'd97: radius_square=17'd9409;
            8'd98: radius_square=17'd9604;
            8'd99: radius_square=17'd9801;
            8'd100: radius_square=17'd10000;
            8'd101: radius_square=17'd10201;
            8'd102: radius_square=17'd10404;
            8'd103: radius_square=17'd10609;
            8'd104: radius_square=17'd10816;
            8'd105: radius_square=17'd11025;
            8'd106: radius_square=17'd11236;
            8'd107: radius_square=17'd11449;
            8'd108: radius_square=17'd11664;
            8'd109: radius_square=17'd11881;
            8'd110: radius_square=17'd12100;
            default: radius_square=17'd8100;
        endcase
    end
    assign base_radius_sq=radius_square;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            frame_start_d<=1'b0;scan_busy<=1'b0;peak_ready<=1'b0;
            scan_index<=7'd0;scan_peak<=8'd0;pending_peak<=8'd0;
            peak_envelope<=8'd0;radius<=8'd90;
        end else begin
            frame_start_d<=frame_start;
            if(frame_start && !frame_start_d) begin
                // 用上一帧已完成的扫描结果更新；随后读取本帧新发布的 FFT 柱。
                if(peak_ready) begin
                    peak_envelope<=next_envelope;
                    radius<=8'd90+{3'd0,radius_offset(next_envelope)};
                end
                peak_ready<=1'b0;scan_busy<=1'b1;
                scan_index<=7'd0;scan_peak<=8'd0;
            end else if(scan_busy) begin
                scan_peak<=next_peak;
                if(scan_index==7'd79) begin
                    pending_peak<=next_peak;peak_ready<=1'b1;scan_busy<=1'b0;
                end else scan_index<=scan_index+7'd1;
            end
        end
    end
end else begin : g_fixed_radius
    assign base_radius=8'd90;
    assign base_radius_sq=17'd8100;
end endgenerate
wire [7:0] local_x = abs_x[7:0];
wire [7:0] local_y = abs_y[7:0];
wire [16:0] distance_sq = (local_x * local_x) + (local_y * local_y);
wire [7:0] major = (local_x >= local_y) ? local_x : local_y;
wire [7:0] minor = (local_x >= local_y) ? local_y : local_x;
wire [17:0] major_wide = {10'd0,major};
wire [17:0] minor256 = {2'd0,minor,8'd0};
// 每个八分圆分为 10 根柱，以常数乘法选择最近中心线，无浮点或除法。
// BEGIN GENERATED TABLES
// 此区由 src/test/generate_ring_visual_tables.py 生成；角度为 Q8 正切。
wire [17:0] bound0 = (major_wide << 1) + (major_wide << 3);
wire [17:0] bound1 = (major_wide << 1) + (major_wide << 2) + (major_wide << 3) + (major_wide << 4);
wire [17:0] bound2 = (major_wide << 0) + (major_wide << 1) + (major_wide << 4) + (major_wide << 5);
wire [17:0] bound3 = (major_wide << 3) + (major_wide << 6);
wire [17:0] bound4 = (major_wide << 1) + (major_wide << 2) + (major_wide << 3) + (major_wide << 4) + (major_wide << 6);
wire [17:0] bound5 = (major_wide << 1) + (major_wide << 2) + (major_wide << 4) + (major_wide << 5) + (major_wide << 6);
wire [17:0] bound6 = (major_wide << 0) + (major_wide << 1) + (major_wide << 2) + (major_wide << 3) + (major_wide << 7);
wire [17:0] bound7 = (major_wide << 0) + (major_wide << 1) + (major_wide << 3) + (major_wide << 5) + (major_wide << 7);
wire [17:0] bound8 = (major_wide << 1) + (major_wide << 3) + (major_wide << 6) + (major_wide << 7);
wire [17:0] bound9 = (major_wide << 0) + (major_wide << 2) + (major_wide << 3) + (major_wide << 5) + (major_wide << 6) + (major_wide << 7);
wire [3:0] octant_position =
    (minor256 < bound0) ? 4'd0 :
    (minor256 < bound1) ? 4'd1 :
    (minor256 < bound2) ? 4'd2 :
    (minor256 < bound3) ? 4'd3 :
    (minor256 < bound4) ? 4'd4 :
    (minor256 < bound5) ? 4'd5 :
    (minor256 < bound6) ? 4'd6 :
    (minor256 < bound7) ? 4'd7 :
    (minor256 < bound8) ? 4'd8 :
    (minor256 < bound9) ? 4'd9 :
    4'd10;
reg [17:0] axis_product;
always @* begin
    case (octant_position)
        4'd0: axis_product = 18'd0;
        4'd1: axis_product = (major_wide << 2) + (major_wide << 4);
        4'd2: axis_product = (major_wide << 0) + (major_wide << 3) + (major_wide << 5);
        4'd3: axis_product = (major_wide << 0) + (major_wide << 2) + (major_wide << 3) + (major_wide << 4) + (major_wide << 5);
        4'd4: axis_product = (major_wide << 0) + (major_wide << 1) + (major_wide << 4) + (major_wide << 6);
        4'd5: axis_product = (major_wide << 1) + (major_wide << 3) + (major_wide << 5) + (major_wide << 6);
        4'd6: axis_product = (major_wide << 1) + (major_wide << 7);
        4'd7: axis_product = (major_wide << 0) + (major_wide << 2) + (major_wide << 3) + (major_wide << 4) + (major_wide << 7);
        4'd8: axis_product = (major_wide << 1) + (major_wide << 3) + (major_wide << 4) + (major_wide << 5) + (major_wide << 7);
        4'd9: axis_product = (major_wide << 0) + (major_wide << 1) + (major_wide << 3) + (major_wide << 4) + (major_wide << 6) + (major_wide << 7);
        4'd10: axis_product = (major_wide << 8);
        default: axis_product = major_wide << 8;
    endcase
end
function [7:0] visual_mapping;
    input [6:0] index;
    begin
        visual_mapping[0] = (80'h0dfff00e53f9aab6de38 >> index) & 1'b1;
        visual_mapping[1] = (80'h0caaaaa1c952ccc71fc0 >> index) & 1'b1;
        visual_mapping[2] = (80'hf93333356d9cf0f80000 >> index) & 1'b1;
        visual_mapping[3] = (80'hf1c3c3c671e0ff000000 >> index) & 1'b1;
        visual_mapping[4] = (80'hfe03fc0781ff00000000 >> index) & 1'b1;
        visual_mapping[5] = (80'hfffc0007fe0000000000 >> index) & 1'b1;
        visual_mapping[6] = (80'hfffffff8000000000000 >> index) & 1'b1;
        visual_mapping[7] = (80'h00000000000000001fff >> index) & 1'b1;
    end
endfunction
function [23:0] rainbow;
    input [6:0] index;
    begin
        rainbow[0] = (80'hf19dfffffff319ffffff >> index) & 1'b1;
        rainbow[1] = (80'hc1e000000030f9ffffff >> index) & 1'b1;
        rainbow[2] = (80'heb540000001aadffffff >> index) & 1'b1;
        rainbow[3] = (80'hd8cdffffffdccfffffff >> index) & 1'b1;
        rainbow[4] = (80'hed69ffffffca5bffffff >> index) & 1'b1;
        rainbow[5] = (80'hf18e00000039c7ffffff >> index) & 1'b1;
        rainbow[6] = (80'hfe0ffffffff83fffffff >> index) & 1'b1;
        rainbow[7] = (80'hfff000000007ffffffff >> index) & 1'b1;
        rainbow[8] = (80'h3ffffff6733ffffffe67 >> index) & 1'b1;
        rainbow[9] = (80'h3ffffff87c0000000e1f >> index) & 1'b1;
        rainbow[10] = (80'h7ffffffad540000004aa >> index) & 1'b1;
        rainbow[11] = (80'h7ffffff9ccfffffff8cc >> index) & 1'b1;
        rainbow[12] = (80'hfffffffd697ffffffa5a >> index) & 1'b1;
        rainbow[13] = (80'hfffffffe718000000639 >> index) & 1'b1;
        rainbow[14] = (80'hffffffff81fffffffe07 >> index) & 1'b1;
        rainbow[15] = (80'hfffffffffe00000001ff >> index) & 1'b1;
        rainbow[16] = (80'hffff9ccfffffffcc6fff >> index) & 1'b1;
        rainbow[17] = (80'h000183cffffffe0f8000 >> index) & 1'b1;
        rainbow[18] = (80'h00012a9ffffffea55000 >> index) & 1'b1;
        rainbow[19] = (80'hffffccefffffff9ccfff >> index) & 1'b1;
        rainbow[20] = (80'hffff5a5fffffff296fff >> index) & 1'b1;
        rainbow[21] = (80'h0000c63fffffffce7000 >> index) & 1'b1;
        rainbow[22] = (80'hffffc1fffffffff07fff >> index) & 1'b1;
        rainbow[23] = (80'h00003fffffffffff8000 >> index) & 1'b1;
    end
endfunction
// END GENERATED TABLES
reg [6:0] sector;
always @* begin
    if (x_right && !y_down) begin
        if (abs_y >= abs_x) sector = {3'd0,octant_position};
        else sector = 7'd20 - {3'd0,octant_position};
    end else if (x_right && y_down) begin
        if (abs_x >= abs_y) sector = 7'd20 + {3'd0,octant_position};
        else sector = 7'd40 - {3'd0,octant_position};
    end else if (!x_right && y_down) begin
        if (abs_y >= abs_x) sector = 7'd40 + {3'd0,octant_position};
        else sector = 7'd60 - {3'd0,octant_position};
    end else begin
        if (abs_x >= abs_y) sector = 7'd60 + {3'd0,octant_position};
        else if (octant_position == 4'd0) sector = 7'd0;
        else sector = 7'd80 - {3'd0,octant_position};
    end
end
// 频率起点旋转到三点钟。视觉查表对原频段作对数重采样，低频占更多柱。
wire [6:0] display_index = (sector >= 7'd20) ? sector - 7'd20 : sector + 7'd60;
wire [7:0] map_word = visual_mapping(display_index);
wire [4:0] band_index = map_word[6:2];
wire [4:0] next_band_index = (band_index == 5'd31) ? 5'd31 : band_index + 5'd1;
wire [7:0] direct_level = map_word[7] ? 8'd0 : bands[band_index*8 +: 8];
wire [7:0] next_level = map_word[7] ? bands[7:0] : bands[next_band_index*8 +: 8];
wire [9:0] a_wide = {2'd0,direct_level};
wire [9:0] b_wide = {2'd0,next_level};
reg [9:0] blend_sum;
always @* begin
    case (map_word[1:0])
        2'd0: blend_sum = a_wide << 2;
        2'd1: blend_sum = (a_wide << 1) + a_wide + b_wide;
        2'd2: blend_sum = (a_wide + b_wide) << 1;
        default: blend_sum = a_wide + (b_wide << 1) + b_wide;
    endcase
end
wire [7:0] interpolated_level = blend_sum[9:2];
reg [7:0] level;
always @* begin
    case (display_index)
        7'd76: level = (interpolated_level >> 1) + (interpolated_level >> 2);
        7'd77: level = interpolated_level >> 1;
        7'd78: level = interpolated_level >> 2;
        7'd79: level = 8'd0;
        default: level = interpolated_level;
    endcase
end
// 第一级锁存幅度与同像素的几何条件；输出供视频呈现第二级使用。
// 不增加整个视频通路的两拍延迟，避免频段选择与半径平方串成超长路径。
wire spectrum_active = REFERENCE_MODE ? (|bars) : (|bands);
wire [17:0] cross_error = (minor256 >= axis_product) ?
    minor256 - axis_product : axis_product - minor256;
wire [8:0] side_limit = (octant_position >= 4'd8) ? 9'd480 :
                       ((octant_position >= 4'd5) ? 9'd416 : 9'd384);
wire [8:0] cap_limit = side_limit >> 1;
reg [7:0] level_stage;
reg [16:0] distance_sq_stage;
reg [7:0] base_radius_stage;
reg [16:0] base_radius_sq_stage;
reg active_stage, inside_side_stage, narrow_center_stage;
reg [23:0] color_stage;
// 数据寄存器每拍覆盖，复位仅清有效标志，减小全局复位网络负担。
always @(posedge clk) begin
    level_stage <= REFERENCE_MODE ? bars[display_index*8 +:8] : level;
    distance_sq_stage <= distance_sq;
    base_radius_stage <= base_radius;
    base_radius_sq_stage <= base_radius_sq;
    inside_side_stage <= cross_error <= {9'd0,side_limit};
    narrow_center_stage <= cross_error <= {9'd0,cap_limit};
    color_stage <= rainbow(display_index);
end
always @(posedge clk or posedge rst) begin
    if (rst) active_stage <= 1'b0;
    else active_stage <= spectrum_active && in_circle_bounds;
end
// 最大长度 63 像素；参考模式有声时最低 8 像素，静音整圈消失。
localparam [5:0] MIN_BAR_LENGTH = REFERENCE_MODE ? 6'd8 : 6'd2;
wire [5:0] scaled_length = level_stage[7:2];
wire [5:0] bar_length = (scaled_length < MIN_BAR_LENGTH) ? MIN_BAR_LENGTH : scaled_length;
wire [7:0] outer_radius = base_radius_stage + {2'd0,bar_length};
wire [16:0] outer_radius_sq = outer_radius * outer_radius;
// 恒定细线宽度；圆帽中央保留尖端像素，两侧各缩一像素。
wire [16:0] cap_body_radius_sq = outer_radius_sq - {8'd0,outer_radius,1'b0} + 17'd1;
wire [16:0] inner_cap_radius_sq = base_radius_sq_stage + {8'd0,base_radius_stage,1'b0} + 17'd1;
wire bar = active_stage && inside_side_stage &&
    (distance_sq_stage >= base_radius_sq_stage) && (distance_sq_stage <= outer_radius_sq) &&
    ((distance_sq_stage >= inner_cap_radius_sq) || narrow_center_stage) &&
    ((distance_sq_stage <= cap_body_radius_sq) || narrow_center_stage);
assign pixel_on = bar;
assign pixel_rgb = color_stage;
endmodule
