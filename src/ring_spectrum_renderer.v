// 以屏幕中心为圆心的 32 段径向音柱。距离平方使内外边界保持圆形。
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
wire [14:0] minor16 = {minor,4'b0000};
wire [14:0] bound0 = {4'd0,major} + ({4'd0,major} >> 1);
wire [14:0] bound1 = ({4'd0,major} << 2) + {4'd0,major};
wire [14:0] bound2 = ({4'd0,major} << 3) + ({4'd0,major} >> 1);
wire [14:0] bound3 = ({4'd0,major} << 3) + ({4'd0,major} << 2) +
                      {4'd0,major};
wire [14:0] gap_margin = {4'd0,major} >> 2;
wire near0 = (minor16 + gap_margin >= bound0) &&
             (minor16 <= bound0 + gap_margin);
wire near1 = (minor16 + gap_margin >= bound1) &&
             (minor16 <= bound1 + gap_margin);
wire near2 = (minor16 + gap_margin >= bound2) &&
             (minor16 <= bound2 + gap_margin);
wire near3 = (minor16 + gap_margin >= bound3) &&
             (minor16 <= bound3 + gap_margin);
wire angular_gap = near0 || near1 || near2 || near3;
wire [2:0] octant_position = (minor16 < bound0) ? 3'd0 :
                              (minor16 < bound1) ? 3'd1 :
                              (minor16 < bound2) ? 3'd2 :
                              (minor16 < bound3) ? 3'd3 : 3'd4;
reg [4:0] sector;
always @* begin
    if (x_right && !y_down) begin
        if (abs_y >= abs_x) sector = {2'b00,octant_position};
        else sector = 5'd8 - {2'b00,octant_position};
    end else if (x_right && y_down) begin
        if (abs_x >= abs_y) sector = 5'd8 + {2'b00,octant_position};
        else sector = 5'd16 - {2'b00,octant_position};
    end else if (!x_right && y_down) begin
        if (abs_y >= abs_x) sector = 5'd16 + {2'b00,octant_position};
        else sector = 5'd24 - {2'b00,octant_position};
    end else begin
        if (abs_x >= abs_y) sector = 5'd24 + {2'b00,octant_position};
        else sector = 5'd0 - {2'b00,octant_position};
    end
end
wire [7:0] level = bands[sector*8 +: 8];
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
    input [4:0] index;
    begin
        case (index)
            5'd0: rainbow = 24'h2ee6ff;
            5'd1: rainbow = 24'h2ebfff;
            5'd2: rainbow = 24'h2e97ff;
            5'd3: rainbow = 24'h2e70ff;
            5'd4: rainbow = 24'h2e49ff;
            5'd5: rainbow = 24'h3a2eff;
            5'd6: rainbow = 24'h612eff;
            5'd7: rainbow = 24'h882eff;
            5'd8: rainbow = 24'hb02eff;
            5'd9: rainbow = 24'hd72eff;
            5'd10: rainbow = 24'hfe2eff;
            5'd11: rainbow = 24'hff2ed9;
            5'd12: rainbow = 24'hff2eb2;
            5'd13: rainbow = 24'hff2e8a;
            5'd14: rainbow = 24'hff2e63;
            5'd15: rainbow = 24'hff2e3c;
            5'd16: rainbow = 24'hff472e;
            5'd17: rainbow = 24'hff6e2e;
            5'd18: rainbow = 24'hff952e;
            5'd19: rainbow = 24'hffbd2e;
            5'd20: rainbow = 24'hffe42e;
            5'd21: rainbow = 24'hf3ff2e;
            5'd22: rainbow = 24'hccff2e;
            5'd23: rainbow = 24'ha5ff2e;
            5'd24: rainbow = 24'h7dff2e;
            5'd25: rainbow = 24'h56ff2e;
            5'd26: rainbow = 24'h2fff2e;
            5'd27: rainbow = 24'h2eff54;
            5'd28: rainbow = 24'h2eff7b;
            5'd29: rainbow = 24'h2effa2;
            5'd30: rainbow = 24'h2effca;
            5'd31: rainbow = 24'h2efff1;
            default: rainbow = 24'hffffff;
        endcase
    end
endfunction
endmodule
