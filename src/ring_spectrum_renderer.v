// 32 个频段插值成 64 根径向音柱。距离平方使内外边界保持圆形。
module ring_spectrum_renderer #(
    parameter integer ACTIVE_WIDTH = 640,
    parameter integer ACTIVE_HEIGHT = 480
)(
    input wire [9:0] pixel_x,
    input wire [9:0] pixel_y,
    input wire [255:0] bands,
    output wire pixel_on,
    output wire [23:0] pixel_rgb
);
localparam [9:0] CENTER_X = ACTIVE_WIDTH / 2;
localparam [9:0] CENTER_Y = ACTIVE_HEIGHT / 2;
wire [10:0] abs_x = (pixel_x >= CENTER_X) ?
                    ({1'b0,pixel_x} - {1'b0,CENTER_X}) :
                    ({1'b0,CENTER_X} - {1'b0,pixel_x});
wire [10:0] abs_y = (pixel_y >= CENTER_Y) ?
                    ({1'b0,pixel_y} - {1'b0,CENTER_Y}) :
                    ({1'b0,CENTER_Y} - {1'b0,pixel_y});
wire x_right = pixel_x >= CENTER_X;
wire y_down = pixel_y >= CENTER_Y;
wire [10:0] major = (abs_x >= abs_y) ? abs_x : abs_y;
wire [10:0] minor = (abs_x >= abs_y) ? abs_y : abs_x;
// 可显示半径不超过 168 像素，先限定范围以缩小平方运算位宽。
wire in_circle_bounds = (abs_x <= 11'd168) && (abs_y <= 11'd168);
wire [7:0] local_x = abs_x[7:0];
wire [7:0] local_y = abs_y[7:0];
// 比较距离平方，避免开方与折线近似造成的棱角。
wire [16:0] distance_sq = (local_x * local_x) + (local_y * local_y);
// 每个八分圆含 8 个柱中心；Q8 正切阈值采用移位加法。
wire [18:0] minor256 = {minor,8'd0};
wire [18:0] major_wide = {8'd0,major};
wire [18:0] bound0 = (major_wide << 0) + (major_wide << 2) + (major_wide << 3);
wire [18:0] bound1 = (major_wide << 1) + (major_wide << 2) + (major_wide << 5);
wire [18:0] bound2 = (major_wide << 6);
wire [18:0] bound3 = (major_wide << 2) + (major_wide << 3) + (major_wide << 4) + (major_wide << 6);
wire [18:0] bound4 = (major_wide << 0) + (major_wide << 3) + (major_wide << 4) + (major_wide << 5) + (major_wide << 6);
wire [18:0] bound5 = (major_wide << 0) + (major_wide << 3) + (major_wide << 4) + (major_wide << 7);
wire [18:0] bound6 = (major_wide << 1) + (major_wide << 2) + (major_wide << 3) + (major_wide << 4) + (major_wide << 5) + (major_wide << 7);
wire [18:0] bound7 = (major_wide << 3) + (major_wide << 5) + (major_wide << 6) + (major_wide << 7);
wire [18:0] gap_margin = major_wide << 1;
wire near0 = (minor256 + gap_margin >= bound0) && (minor256 <= bound0 + gap_margin);
wire near1 = (minor256 + gap_margin >= bound1) && (minor256 <= bound1 + gap_margin);
wire near2 = (minor256 + gap_margin >= bound2) && (minor256 <= bound2 + gap_margin);
wire near3 = (minor256 + gap_margin >= bound3) && (minor256 <= bound3 + gap_margin);
wire near4 = (minor256 + gap_margin >= bound4) && (minor256 <= bound4 + gap_margin);
wire near5 = (minor256 + gap_margin >= bound5) && (minor256 <= bound5 + gap_margin);
wire near6 = (minor256 + gap_margin >= bound6) && (minor256 <= bound6 + gap_margin);
wire near7 = (minor256 + gap_margin >= bound7) && (minor256 <= bound7 + gap_margin);
wire angular_gap = near0 || near1 || near2 || near3 || near4 || near5 || near6 || near7;
wire [3:0] octant_position =
    (minor256 < bound0) ? 4'd0 :
    (minor256 < bound1) ? 4'd1 :
    (minor256 < bound2) ? 4'd2 :
    (minor256 < bound3) ? 4'd3 :
    (minor256 < bound4) ? 4'd4 :
    (minor256 < bound5) ? 4'd5 :
    (minor256 < bound6) ? 4'd6 :
    (minor256 < bound7) ? 4'd7 :
    4'd8;
reg [5:0] sector;
always @* begin
    if (x_right && !y_down) begin
        if (abs_y >= abs_x) sector = {2'b00,octant_position};
        else sector = 6'd16 - {2'b00,octant_position};
    end else if (x_right && y_down) begin
        if (abs_x >= abs_y) sector = 6'd16 + {2'b00,octant_position};
        else sector = 6'd32 - {2'b00,octant_position};
    end else if (!x_right && y_down) begin
        if (abs_y >= abs_x) sector = 6'd32 + {2'b00,octant_position};
        else sector = 6'd48 - {2'b00,octant_position};
    end else begin
        if (abs_x >= abs_y) sector = 6'd48 + {2'b00,octant_position};
        else sector = 6'd0 - {2'b00,octant_position};
    end
end
// 偶数柱使用原频段，奇数柱使用相邻频段平均值；末柱环绕到频段 0。
wire [4:0] band_index = sector[5:1];
wire [4:0] next_band_index = band_index + 5'd1;
wire [7:0] direct_level = bands[band_index*8 +: 8];
wire [7:0] next_level = bands[next_band_index*8 +: 8];
wire [8:0] level_sum = {1'b0,direct_level} + {1'b0,next_level};
wire [7:0] level = sector[0] ? level_sum[8:1] : direct_level;
wire [7:0] bar_length = {2'd0,level[7:2]} + {4'd0,level[7:4]};
wire [8:0] outer_radius = 9'd90 + {1'b0,bar_length};
wire [17:0] outer_radius_sq = outer_radius * outer_radius;
wire bar = in_circle_bounds &&
           (distance_sq > 17'd8100) &&
           ({1'b0,distance_sq} <= outer_radius_sq) &&
           !angular_gap;
assign pixel_on = bar;
assign pixel_rgb = rainbow(sector);

function [23:0] rainbow;
    input [5:0] index;
    begin
        case (index)
            6'd0: rainbow = 24'h2ee6ff;
            6'd1: rainbow = 24'h2ed2ff;
            6'd2: rainbow = 24'h2ebfff;
            6'd3: rainbow = 24'h2eabff;
            6'd4: rainbow = 24'h2e97ff;
            6'd5: rainbow = 24'h2e83ff;
            6'd6: rainbow = 24'h2e70ff;
            6'd7: rainbow = 24'h2e5cff;
            6'd8: rainbow = 24'h2e49ff;
            6'd9: rainbow = 24'h343bff;
            6'd10: rainbow = 24'h3a2eff;
            6'd11: rainbow = 24'h4d2eff;
            6'd12: rainbow = 24'h612eff;
            6'd13: rainbow = 24'h742eff;
            6'd14: rainbow = 24'h882eff;
            6'd15: rainbow = 24'h9c2eff;
            6'd16: rainbow = 24'hb02eff;
            6'd17: rainbow = 24'hc32eff;
            6'd18: rainbow = 24'hd72eff;
            6'd19: rainbow = 24'hea2eff;
            6'd20: rainbow = 24'hfe2eff;
            6'd21: rainbow = 24'hfe2eec;
            6'd22: rainbow = 24'hff2ed9;
            6'd23: rainbow = 24'hff2ec5;
            6'd24: rainbow = 24'hff2eb2;
            6'd25: rainbow = 24'hff2e9e;
            6'd26: rainbow = 24'hff2e8a;
            6'd27: rainbow = 24'hff2e76;
            6'd28: rainbow = 24'hff2e63;
            6'd29: rainbow = 24'hff2e4f;
            6'd30: rainbow = 24'hff2e3c;
            6'd31: rainbow = 24'hff3a35;
            6'd32: rainbow = 24'hff472e;
            6'd33: rainbow = 24'hff5a2e;
            6'd34: rainbow = 24'hff6e2e;
            6'd35: rainbow = 24'hff812e;
            6'd36: rainbow = 24'hff952e;
            6'd37: rainbow = 24'hffa92e;
            6'd38: rainbow = 24'hffbd2e;
            6'd39: rainbow = 24'hffd02e;
            6'd40: rainbow = 24'hffe42e;
            6'd41: rainbow = 24'hf9f12e;
            6'd42: rainbow = 24'hf3ff2e;
            6'd43: rainbow = 24'hdfff2e;
            6'd44: rainbow = 24'hccff2e;
            6'd45: rainbow = 24'hb8ff2e;
            6'd46: rainbow = 24'ha5ff2e;
            6'd47: rainbow = 24'h91ff2e;
            6'd48: rainbow = 24'h7dff2e;
            6'd49: rainbow = 24'h69ff2e;
            6'd50: rainbow = 24'h56ff2e;
            6'd51: rainbow = 24'h42ff2e;
            6'd52: rainbow = 24'h2fff2e;
            6'd53: rainbow = 24'h2eff41;
            6'd54: rainbow = 24'h2eff54;
            6'd55: rainbow = 24'h2eff67;
            6'd56: rainbow = 24'h2eff7b;
            6'd57: rainbow = 24'h2eff8e;
            6'd58: rainbow = 24'h2effa2;
            6'd59: rainbow = 24'h2effb6;
            6'd60: rainbow = 24'h2effca;
            6'd61: rainbow = 24'h2effdd;
            6'd62: rainbow = 24'h2efff1;
            6'd63: rainbow = 24'h2ef2f8;
            default: rainbow = 24'hffffff;
        endcase
    end
endfunction
endmodule
