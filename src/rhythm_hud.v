// 消隐内共享 BCD 转换器并写字符 RAM；像素侧只读一字节，避免多组数值桶形选择器。
module rhythm_hud #(parameter integer STREAM_METADATA=0,parameter integer BLOCK_CHARACTERS=0)(
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
    assign metadata_address=(next_address>=64 && next_address<88) ? {1'b0,next_address[4:0]} :
        ((next_address>=96 && next_address<109) ? 6'd24+{2'd0,next_address[3:0]} : 6'd0);
    reg [7:0] initial_char;
    always @*begin
        initial_char=" ";
        if(address>=64 && address<88)initial_char=STREAM_METADATA ? (metadata_valid ? metadata_data : 8'h20) : title[{address[4:0],3'd0} +:8];
        else if(address>=96 && address<109)initial_char=STREAM_METADATA ? (metadata_valid ? metadata_data : 8'h20) : difficulty[{address[3:0],3'd0} +:8];
        else if(address>=112 && address<128)initial_char=status_text[{~address[3:0],3'b111} -:8];
        else case(address)
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
    always @*begin
        text_area=0;rel_x=0;rel_y=0;read_address=0;text_base=0;
        if(y>=12 && y<28 && x>=(512-(BLOCK_CHARACTERS ? 2 : 0)) && x<624)begin text_area=1;rel_x=x-512;rel_y=y-12;text_base=0;end
        else if(y>=12 && y<28 && x>=(280-(BLOCK_CHARACTERS ? 2 : 0)) && x<360)begin text_area=1;rel_x=x-280;rel_y=y-12;text_base=16;end
        else if(y>=32 && y<48 && x>=(280-(BLOCK_CHARACTERS ? 2 : 0)) && x<360)begin text_area=1;rel_x=x-280;rel_y=y-32;text_base=32;end
        else if(y>=48 && y<64 && x>=(24-(BLOCK_CHARACTERS ? 2 : 0)) && x<88)begin text_area=1;rel_x=x-24;rel_y=y-48;text_base=48;end
        else if(y>=448 && y<464 && x>=(24-(BLOCK_CHARACTERS ? 2 : 0)) && x<408)begin text_area=1;rel_x=x-24;rel_y=y-448;text_base=64;end
        else if(y>=448 && y<464 && x>=(416-(BLOCK_CHARACTERS ? 2 : 0)) && x<624)begin text_area=1;rel_x=x-416;rel_y=y-448;text_base=96;end
        else if(saved_state!=6 && saved_state!=9 && y>=176 && y<192 && x>=(192-(BLOCK_CHARACTERS ? 2 : 0)) && x<448)begin text_area=1;rel_x=x-192;rel_y=y-176;text_base=112;end
        else if(saved_state==11 && y>=208 && y<224 && x>=(304-(BLOCK_CHARACTERS ? 2 : 0)) && x<336)begin text_area=1;rel_x=x-304;rel_y=y-208;text_base=128;end
        else if(saved_state==10 && y>=208 && y<288 && x>=(224-(BLOCK_CHARACTERS ? 2 : 0)) && x<368)begin
            text_area=1;rel_x=x-224;rel_y={6'd0,y[3:0]};text_base=8'd144+{y[6:4]-3'd5,4'd0};
        end
        read_address=text_base+{3'd0,read_x[8:4]};
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
