// 消隐内共享 BCD 转换器并写字符 RAM；像素侧只读一字节，避免多组数值桶形选择器。
module rhythm_hud #(parameter integer STREAM_METADATA=0,parameter integer BLOCK_CHARACTERS=0,
    parameter integer TEXT_ROM=1)(
    input wire clk,input wire rst,input wire frame_start,
    input wire [3:0] state,error_code,input wire auto_mode,
    input wire [19:0] score,input wire [15:0] combo,max_combo,perfect_count,good_count,bad_count,miss_count,
    input wire metadata_valid,input wire [7:0] metadata_data,output wire [5:0] metadata_address,
    input wire [191:0] title,input wire [127:0] difficulty,
    input wire [9:0] x,y,
    output reg text_area,output reg [9:0] rel_x,rel_y,output wire [7:0] character
);
    reg [2:0] field;
    wire [19:0] selected_value;
    reg [19:0] live_value;
    always @*case(field)
        0:live_value=score;1:live_value={4'd0,combo};2:live_value={4'd0,max_combo};
        3:live_value={4'd0,perfect_count};4:live_value={4'd0,good_count};
        5:live_value={4'd0,bad_count};default:live_value={4'd0,miss_count};
    endcase
    // 板级捕获期间判定暂停，首次数字转换前分数长除法也已完成，可复用稳定计数。
    generate if(BLOCK_CHARACTERS)begin: frozen_values
        assign selected_value=live_value;
    end else begin: snapshot_values
        reg [19:0] values[0:6];
        always @(posedge clk)if(frame_start)begin
            values[0]<=score;values[1]<={4'd0,combo};values[2]<={4'd0,max_combo};values[3]<={4'd0,perfect_count};
            values[4]<={4'd0,good_count};values[5]<={4'd0,bad_count};values[6]<={4'd0,miss_count};
        end
        assign selected_value=values[field];
    end endgenerate
    reg [1:0] phase;reg [7:0] address;reg [4:0] left;
    reg [19:0] shift_value;reg [27:0] bcd;reg [3:0] saved_state,saved_error;reg saved_auto;
    reg [127:0] status_text;
    always @*begin
        case(saved_state)
            2:status_text="STOP - SW1 START";4:status_text="LOADING         ";5:status_text="READY           ";
            7:status_text="PAUSED          ";8:status_text="BUFFERING       ";10:status_text="RESULT          ";
            11:status_text="ERROR           ";default:status_text="                ";
        endcase
    end
    wire [7:0] next_address=address+8'd1;
    wire [7:0] static_char;
    generate if(TEXT_ROM)begin: static_text
        reg [7:0] text_rom[0:1023];
        reg [7:0] text_data;
        integer text_index;
        initial begin
            for(text_index=0;text_index<1024;text_index=text_index+1)text_rom[text_index]=8'h20;
// BEGIN HUD TEXT ROM
            text_rom[32]=8'h43;
            text_rom[33]=8'h4f;
            text_rom[34]=8'h4d;
            text_rom[35]=8'h42;
            text_rom[36]=8'h4f;
            text_rom[48]=8'h41;
            text_rom[49]=8'h55;
            text_rom[50]=8'h54;
            text_rom[51]=8'h4f;
            text_rom[128]=8'h45;
            text_rom[144]=8'h50;
            text_rom[160]=8'h47;
            text_rom[176]=8'h42;
            text_rom[192]=8'h4d;
            text_rom[208]=8'h43;
            text_rom[288]=8'h43;
            text_rom[289]=8'h4f;
            text_rom[290]=8'h4d;
            text_rom[291]=8'h42;
            text_rom[292]=8'h4f;
            text_rom[304]=8'h54;
            text_rom[305]=8'h45;
            text_rom[306]=8'h53;
            text_rom[307]=8'h54;
            text_rom[384]=8'h45;
            text_rom[400]=8'h50;
            text_rom[416]=8'h47;
            text_rom[432]=8'h42;
            text_rom[448]=8'h4d;
            text_rom[464]=8'h43;
            text_rom[544]=8'h53;
            text_rom[545]=8'h54;
            text_rom[546]=8'h4f;
            text_rom[547]=8'h50;
            text_rom[549]=8'h2d;
            text_rom[551]=8'h53;
            text_rom[552]=8'h57;
            text_rom[553]=8'h31;
            text_rom[555]=8'h53;
            text_rom[556]=8'h54;
            text_rom[557]=8'h41;
            text_rom[558]=8'h52;
            text_rom[559]=8'h54;
            text_rom[576]=8'h4c;
            text_rom[577]=8'h4f;
            text_rom[578]=8'h41;
            text_rom[579]=8'h44;
            text_rom[580]=8'h49;
            text_rom[581]=8'h4e;
            text_rom[582]=8'h47;
            text_rom[592]=8'h52;
            text_rom[593]=8'h45;
            text_rom[594]=8'h41;
            text_rom[595]=8'h44;
            text_rom[596]=8'h59;
            text_rom[624]=8'h50;
            text_rom[625]=8'h41;
            text_rom[626]=8'h55;
            text_rom[627]=8'h53;
            text_rom[628]=8'h45;
            text_rom[629]=8'h44;
            text_rom[640]=8'h42;
            text_rom[641]=8'h55;
            text_rom[642]=8'h46;
            text_rom[643]=8'h46;
            text_rom[644]=8'h45;
            text_rom[645]=8'h52;
            text_rom[646]=8'h49;
            text_rom[647]=8'h4e;
            text_rom[648]=8'h47;
            text_rom[672]=8'h52;
            text_rom[673]=8'h45;
            text_rom[674]=8'h53;
            text_rom[675]=8'h55;
            text_rom[676]=8'h4c;
            text_rom[677]=8'h54;
            text_rom[688]=8'h45;
            text_rom[689]=8'h52;
            text_rom[690]=8'h52;
            text_rom[691]=8'h4f;
            text_rom[692]=8'h52;
// END HUD TEXT ROM
        end
        // 顺序填充时预取下一地址，状态文本占独立的 16x16 区域。
        wire [9:0] text_address=(next_address>=112 && next_address<128) ?
            {2'b10,saved_state,next_address[3:0]} : {1'b0,!saved_auto,next_address};
        always @(posedge clk)text_data<=text_rom[text_address];
        assign static_char=address==0 ? 8'h20 : text_data;
    end else begin: logic_text
        assign static_char=8'h20;
    end endgenerate
    assign metadata_address=(next_address>=64 && next_address<88) ? {1'b0,next_address[4:0]} :
        ((next_address>=96 && next_address<109) ? 6'd24+{2'd0,next_address[3:0]} : 6'd0);
    reg [7:0] initial_char;
    always @*begin
        initial_char=TEXT_ROM ? static_char : 8'h20;
        if(address>=64 && address<88)initial_char=STREAM_METADATA ? (metadata_valid ? metadata_data : 8'h20) : title[{address[4:0],3'd0} +:8];
        else if(address>=96 && address<109)initial_char=STREAM_METADATA ? (metadata_valid ? metadata_data : 8'h20) : difficulty[{address[3:0],3'd0} +:8];
        else if(address==129)initial_char=(saved_error>=11 && saved_error<=14) ? "8" : (saved_error<10 ? 8'h30+{4'd0,saved_error} : "A");
        else if(address==130)case(saved_error)
            11:initial_char="H";12:initial_char="L";13:initial_char="F";14:initial_char="M";default:initial_char=8'h20;
        endcase
        else if(!TEXT_ROM && address>=112 && address<128)initial_char=status_text[{~address[3:0],3'b111} -:8];
        else if(!TEXT_ROM)case(address)
            32:initial_char="C";33:initial_char="O";34:initial_char="M";35:initial_char="B";36:initial_char="O";
            48:initial_char=saved_auto ? "A" : "T";49:initial_char=saved_auto ? "U" : "E";
            50:initial_char=saved_auto ? "T" : "S";51:initial_char=saved_auto ? "O" : "T";
            128:initial_char="E";129:initial_char=saved_error<10 ? 8'h30+{4'd0,saved_error} : "A";
            144:initial_char="P";160:initial_char="G";176:initial_char="B";192:initial_char="M";208:initial_char="C";
            default:begin end
        endcase
    end
    reg [27:0] adjusted;
    integer i;
    always @*begin
        adjusted=bcd;
        for(i=0;i<7;i=i+1)if(adjusted[i*4 +:4]>=5)adjusted[i*4 +:4]=adjusted[i*4 +:4]+4'd3;
    end
    function [7:0] field_address;
        input [2:0] f;
        begin case(f)0:field_address=0;1:field_address=16;2:field_address=212;3:field_address=148;
            4:field_address=164;5:field_address=180;default:field_address=196;endcase end
    endfunction
    always @(posedge clk or posedge rst)begin
        if(rst)begin phase<=0;address<=0;field<=0;left<=0;shift_value<=0;bcd<=0;saved_state<=2;saved_error<=0;saved_auto<=1;end
        else if(frame_start)begin
            saved_state<=state;saved_error<=error_code;saved_auto<=auto_mode;phase<=1;address<=0;field<=0;
        end else case(phase)
            1:begin
                if(address==255)begin phase<=2;field<=0;shift_value<=BLOCK_CHARACTERS ? score : selected_value;bcd<=0;left<=20;end
                else address<=address+8'd1;
            end
            2:if(left==0)begin shift_value<=selected_value;bcd<=0;left<=20;end else begin
                bcd<={adjusted[26:0],shift_value[19]};shift_value<=shift_value<<1;left<=left-5'd1;
                if(left==1)begin phase<=3;address<=field_address(field);left<=field==0 ? 5'd7 : 5'd5;end
            end
            3:begin
                bcd<=bcd<<4;address<=address+8'd1;left<=left-5'd1;
                if(left==1)begin
                    if(field==6)phase<=0;
                    else begin field<=field+3'd1;bcd<=0;left<=0;phase<=2;end
                end
            end
            default:phase<=0;
        endcase
    end
    wire character_we=!rst && !frame_start && (phase==1 || phase==3);
    wire [7:0] character_write=phase==1 ? initial_char : 8'h30+{4'd0,(field==0 ? bcd[27:24] : bcd[19:16])};
    reg [7:0] read_address;
    reg [7:0] text_base;wire [9:0] read_x=rel_x+(BLOCK_CHARACTERS ? 10'd2 : 10'd0);
    reg line_valid0,line_valid1;
    reg [9:0] line_left0,line_right0,line_left1,line_right1;
    reg [7:0] line_base0,line_base1;
    reg [3:0] line_rel_y;
    reg [9:0] area_x;
    // 每行第零像素装载至多两段文字，后续像素只比较横坐标，避免重复展开页面与纵坐标优先链。
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            line_valid0<=1'b0;line_valid1<=1'b0;line_left0<=10'd0;line_right0<=10'd0;
            line_left1<=10'd0;line_right1<=10'd0;line_base0<=8'd0;line_base1<=8'd0;line_rel_y<=4'd0;
        end else if(x==10'd0)begin
            line_valid0<=1'b0;line_valid1<=1'b0;line_left0<=10'd0;line_right0<=10'd0;
            line_left1<=10'd0;line_right1<=10'd0;line_base0<=8'd0;line_base1<=8'd0;line_rel_y<=y[3:0];
            if(y>=10'd12 && y<10'd28)begin
                line_valid0<=1'b1;line_left0<=BLOCK_CHARACTERS ? 10'd510 : 10'd512;line_right0<=10'd624;line_base0<=8'd0;
                line_valid1<=1'b1;line_left1<=BLOCK_CHARACTERS ? 10'd278 : 10'd280;line_right1<=10'd360;line_base1<=8'd16;
                line_rel_y<=y[3:0]-4'd12;
            end else if(y>=10'd32 && y<10'd48)begin
                line_valid0<=1'b1;line_left0<=BLOCK_CHARACTERS ? 10'd278 : 10'd280;line_right0<=10'd360;line_base0<=8'd32;
            end else if(y>=10'd48 && y<10'd64)begin
                line_valid0<=1'b1;line_left0<=BLOCK_CHARACTERS ? 10'd22 : 10'd24;line_right0<=10'd88;line_base0<=8'd48;
            end else if(y>=10'd448 && y<10'd464)begin
                line_valid0<=1'b1;line_left0<=BLOCK_CHARACTERS ? 10'd22 : 10'd24;line_right0<=10'd408;line_base0<=8'd64;
                line_valid1<=1'b1;line_left1<=BLOCK_CHARACTERS ? 10'd414 : 10'd416;line_right1<=10'd624;line_base1<=8'd96;
            end else if(saved_state!=4'd6 && saved_state!=4'd9 && y>=10'd176 && y<10'd192)begin
                line_valid0<=1'b1;line_left0<=BLOCK_CHARACTERS ? 10'd190 : 10'd192;line_right0<=10'd448;line_base0<=8'd112;
            end else if(saved_state==4'd11 && y>=10'd208 && y<10'd224)begin
                line_valid0<=1'b1;line_left0<=BLOCK_CHARACTERS ? 10'd294 : 10'd296;line_right0<=10'd344;line_base0<=8'd128;
            end else if(saved_state==4'd10 && y>=10'd208 && y<10'd288)begin
                line_valid0<=1'b1;line_left0<=BLOCK_CHARACTERS ? 10'd222 : 10'd224;line_right0<=10'd368;
                line_base0<=8'd144+{y[6:4]-3'd5,4'd0};
            end
        end
    end
    always @*begin
        text_area=0;rel_x=0;rel_y=0;read_address=0;text_base=0;
        area_x=0;
        if(line_valid0 && x>=line_left0 && x<line_right0)begin
            text_area=1'b1;area_x=line_left0+(BLOCK_CHARACTERS ? 10'd2 : 10'd0);text_base=line_base0;
        end else if(line_valid1 && x>=line_left1 && x<line_right1)begin
            text_area=1'b1;area_x=line_left1+(BLOCK_CHARACTERS ? 10'd2 : 10'd0);text_base=line_base1;
        end
        // 两段描述共享横坐标减法；纵向局部坐标已在行首计算。
        if(text_area)begin rel_x=x-area_x;rel_y={6'd0,line_rel_y};end
        // 基址按 16 对齐，字符索引的最高位只影响基址高四位。
        read_address={text_base[7:4]+{3'd0,read_x[8]},read_x[7:4]};
    end
    // 字符缓存单写口；块 RAM 同步读与渲染器第一拍坐标寄存对齐。
    generate if(BLOCK_CHARACTERS)begin: block_characters
        rhythm_block_ram #(.IMPLEMENT("9K"),.WIDTH(8),.ADDRESS_BITS(8),.DEPTH(256)) ram(
            .write_clk(clk),.write_enable(character_we),.write_address(address),.write_data(character_write),
            .read_clk(clk),.read_address(read_address),.read_data(character));
    end else begin: distributed_characters
        reg [7:0] characters[0:255];
        always @(posedge clk)if(character_we)characters[address]<=character_write;
        assign character=characters[read_address];
    end endgenerate
endmodule
