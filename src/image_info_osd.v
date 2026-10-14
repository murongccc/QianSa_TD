// 右侧中文图片信息栏。同步字库与区域/颜色判断同拍锁存，输出为像素流水第一级。
module image_info_osd #(
    parameter integer ACTIVE_WIDTH=640, parameter integer ACTIVE_HEIGHT=480
)(
    input wire clk,rst,frame_start,enable,de,
    input wire [9:0] pixel_x,pixel_y,
    input wire [87:0] image_info,
    input wire [6:0] brightness,contrast,
    input wire [1:0] selected,
    output reg panel_on,output wire ink_on,output wire [23:0] ink_rgb
);
localparam integer PANEL_X=ACTIVE_WIDTH-240;
localparam [5:0] SPACE=6'd47;
function [15:0] size_bcd;
    input integer value;
    integer n,v;
    begin
        size_bcd=0;v=value;
        for(n=0;n<4;n=n+1)begin size_bcd[n*4 +: 4]=v%10;v=v/10;end
    end
endfunction
localparam [31:0] OUTPUT_DIMENSIONS={size_bcd(ACTIVE_WIDTH),size_bcd(ACTIVE_HEIGHT)};
reg [11:0] brightness_bcd,contrast_bcd;
reg [1:0] selected_frame;
function [11:0] parameter_bcd;
    input [6:0] value;
    reg [3:0] tens,ones;
    begin
        tens=value/7'd10;ones=value%7'd10;
        if(value>=7'd100)parameter_bcd=12'h100;
        else parameter_bcd={4'd0,tens,ones};
    end
endfunction
// 每行前11个半角单元放中文标签，数值自第13个单元开始，避免位数变化移动标签。
function [5:0] label_glyph;
    input [2:0] line;input [2:0] index;
    begin
        label_glyph=SPACE;
        case(line)
            0:case(index)0:label_glyph=0;1:label_glyph=1;2:label_glyph=2;3:label_glyph=3;4:label_glyph=4;endcase
            1:case(index)0:label_glyph=0;1:label_glyph=5;2:label_glyph=2;3:label_glyph=3;4:label_glyph=4;endcase
            2:case(index)0:label_glyph=6;1:label_glyph=7;2:label_glyph=8;3:label_glyph=9;endcase
            3:case(index)0:label_glyph=10;1:label_glyph=11;2:label_glyph=8;3:label_glyph=9;endcase
            4:case(index)0:label_glyph=12;1:label_glyph=13;endcase
            5:case(index)0:label_glyph=14;1:label_glyph=15;2:label_glyph=13;endcase
        endcase
    end
endfunction
function [5:0] dimension_char;
    input [31:0] dimensions;input [3:0] index;
    reg [15:0] number;reg [3:0] value;
    begin
        number=index<4 ? dimensions[31:16] : dimensions[15:0];
        case(index)0,5:value=number[15:12];1,6:value=number[11:8];2,7:value=number[7:4];default:value=number[3:0];endcase
        if(index==4)dimension_char=6'd42;
        else if((index==0 || index==5) && number<16'h1000)dimension_char=SPACE;
        else if((index==1 || index==6) && number<16'h0100)dimension_char=SPACE;
        else if((index==2 || index==7) && number<16'h0010)dimension_char=SPACE;
        else dimension_char=6'd32+{2'd0,value};
    end
endfunction
function [5:0] ratio_char;
    input [27:0] number;input [3:0] index;
    reg [3:0] value;
    begin
        case(index)0:value=number[27:24];1:value=number[23:20];2:value=number[19:16];3:value=number[15:12];4:value=number[11:8];6:value=number[7:4];default:value=number[3:0];endcase
        if(index==5)ratio_char=6'd43;
        else if(index==8)ratio_char=6'd44;
        else if((index==0 && number<28'h1000000) || (index==1 && number<28'h0100000) ||
                (index==2 && number<28'h0010000) || (index==3 && number<28'h0001000))ratio_char=SPACE;
        else ratio_char=6'd32+{2'd0,value};
    end
endfunction
wire [9:0] rel_x=pixel_x-(PANEL_X+8);
wire [4:0] cell_x=rel_x[7:3];
reg text_area;reg [2:0] line;reg [3:0] glyph_y;
reg row_half;
always @* begin
    // 行距24=3个8像素块。直接译码块号，避免六组宽比较/减法器占用进位链。
    text_area=pixel_y[9:8]==2'b00;line=0;row_half=0;
    case(pixel_y[7:3])
        5'd3:begin line=0;row_half=0;end
        5'd4:begin line=0;row_half=1;end
        5'd6:begin line=1;row_half=0;end
        5'd7:begin line=1;row_half=1;end
        5'd9:begin line=2;row_half=0;end
        5'd10:begin line=2;row_half=1;end
        5'd12:begin line=3;row_half=0;end
        5'd13:begin line=3;row_half=1;end
        5'd15:begin line=4;row_half=0;end
        5'd16:begin line=4;row_half=1;end
        5'd18:begin line=5;row_half=0;end
        5'd19:begin line=5;row_half=1;end
        default:text_area=0;
    endcase
    glyph_y={row_half,pixel_y[2:0]};
end
wire highlighted=(line==4 && selected_frame==0) || (line==5 && selected_frame==1);
reg [5:0] glyph;reg half;
reg [11:0] parameter_value;
reg [3:0] parameter_digit;
always @* begin
    glyph=SPACE;half=0;parameter_value=line==4 ? brightness_bcd : contrast_bcd;
    parameter_digit=0;
    if(cell_x==0 && highlighted)glyph=6'd48;
    else if(cell_x>=1 && cell_x<=10)begin glyph=label_glyph(line,(cell_x-1'b1)>>1);half=~cell_x[0];end
    else if(cell_x==11)glyph=6'd45;
    else if(cell_x>=13 && cell_x<=21)begin
        case(line)
            0:glyph=dimension_char(image_info[87:56],cell_x-5'd13);
            1:glyph=dimension_char(OUTPUT_DIMENSIONS,cell_x-5'd13);
            2:glyph=ratio_char(image_info[55:28],cell_x-5'd13);
            3:glyph=ratio_char(image_info[27:0],cell_x-5'd13);
            default:begin
                case(cell_x)
                    13:begin parameter_digit=parameter_value[11:8];glyph=parameter_digit==0 ? SPACE : 6'd32+{2'd0,parameter_digit};end
                    14:begin parameter_digit=parameter_value[7:4];glyph=parameter_value<12'h010 ? SPACE : 6'd32+{2'd0,parameter_digit};end
                    15:glyph=6'd32+{2'd0,parameter_value[3:0]};
                    16:glyph=6'd46;
                    17:glyph=6'd33;
                    18,19:glyph=6'd32;
                    default:glyph=SPACE;
                endcase
            end
        endcase
    end
end
// 字库前半为16个汉字，后半为数字符号；无需地址加法和二级半字节ROM。
wire [8:0] font_address={glyph[5],glyph[3:0],glyph_y};
wire [15:0] font_bits;
reg [3:0] glyph_x_stage;
reg text_stage,highlight_stage,arrow_stage,arrow_pixel_stage;
wire [3:0] arrow_dy=glyph_y>=4'd8 ? glyph_y-4'd8 : 4'd8-glyph_y;
wire arrow_pixel=rel_x[2:0]>=3'd1 && rel_x[2:0]<=3'd6 &&
    ({2'd0,rel_x[2:0]}+{1'b0,arrow_dy}<=5'd6);
image_osd_font u_font(.clk(clk),.address(font_address),.bits(font_bits));
assign ink_on=text_stage && (arrow_stage ? arrow_pixel_stage : font_bits[4'd15-glyph_x_stage]);
assign ink_rgb=highlight_stage ? 24'hffdf40 : 24'hffffff;
always @(posedge clk or posedge rst)begin
    if(rst)begin
        brightness_bcd<=12'h050;contrast_bcd<=12'h050;selected_frame<=0;
        panel_on<=0;text_stage<=0;glyph_x_stage<=0;highlight_stage<=0;arrow_stage<=0;arrow_pixel_stage<=0;
    end else begin
        if(frame_start)begin brightness_bcd<=parameter_bcd(brightness);contrast_bcd<=parameter_bcd(contrast);selected_frame<=selected;end
        panel_on<=enable && de && pixel_x>=PANEL_X && pixel_x<PANEL_X+224 && pixel_y>=16 && pixel_y<176;
        text_stage<=enable && de && text_area && pixel_x>=PANEL_X+8 && pixel_x<PANEL_X+216;
        glyph_x_stage<={glyph[5] ? 1'b0 : half,rel_x[2:0]};highlight_stage<=highlighted;
        arrow_stage<=glyph==6'd48;arrow_pixel_stage<=arrow_pixel;
    end
end
endmodule
