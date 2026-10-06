`timescale 1ns/1ps
// 独立逐像素图案参考，覆盖四轨、重叠音符、裁剪、Hold 锚定与同步几何 RAM。
module tb_rhythm_note_style;
    parameter integer BLOCK_GEOMETRY=1;
    reg clk=0;always #20 clk=~clk;
    reg rst=1,de=0,vs=0;reg [3:0] holding=0;
    wire [4:0] vi;reg vv;reg [31:0] start,finish;
    wire capture,active,on;wire [23:0] color;
    rhythm_game_renderer #(.BLOCK_GEOMETRY(BLOCK_GEOMETRY),.STREAM_METADATA(1),.BLOCK_HUD(1)) renderer(
        .clk(clk),.rst(rst),.enabled(1'b1),.de(de),.vs(vs),.song_time(33'sd48000),.song_frames(32'd192000),
        .state(4'd6),.error_code(4'd0),.auto_mode(1'b1),.score(20'd123450),.combo(16'd32),.max_combo(16'd32),
        .perfect_count(16'd32),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
        .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
        .view_index(vi),.view_valid(vv),.view_start(start),.view_end(finish),.holding_mask(holding),
        .capture_busy(capture),.frame_enabled(active),.pixel_on(on),.pixel_rgb(color));

    integer bottom[0:31],tail[0:31];reg valid[0:31],is_hold[0:31];
    always @*begin
        vv=valid[vi];start=48000+(384-bottom[vi])*300;finish=48000+(384-tail[vi])*300;
    end
    function [23:0] bright;
        input integer lane;
        begin case(lane)0:bright=24'hffcf28;1:bright=24'hff7900;2:bright=24'hed2166;default:bright=24'hce3cf0;endcase end
    endfunction
    function [23:0] dark;
        input integer lane;
        begin case(lane)0:dark=24'h997b18;1:dark=24'h994900;2:dark=24'h8e143d;default:dark=24'h7c2490;endcase end
    endfunction
    // 箭头以逐行笔画范围描述，不复用 DUT 的斜线计算表达式。
    function chevron;
        input integer row,distance;
        begin case(row)
            11:chevron=distance==12;
            12:chevron=distance>=10 && distance<=12;
            13:chevron=distance>=8 && distance<=12;
            14:chevron=distance>=6 && distance<=11;
            15:chevron=distance>=4 && distance<=9;
            16:chevron=distance>=2 && distance<=7;
            17:chevron=distance<=5;
            18:chevron=distance<=3;
            19:chevron=distance<=1;
            default:chevron=0;
        endcase end
    endfunction
    function integer corner;
        input integer row;
        begin case(row)0,31:corner=4;1,30:corner=2;2,3,28,29:corner=1;default:corner=0;endcase end
    endfunction
    function [23:0] reference_pixel;
        input integer x,y;
        integer lane,lx,i,slot,head,body,b,hr,tr,padding,distance;
        reg white;
        begin
            reference_pixel=24'h302418;
            if(x>=96 && x<544 && y>=64 && y<409)begin
                lane=(x-96)/112;lx=(x-96)%112;head=-1;body=-1;hr=0;tr=0;
                if(lx==0)reference_pixel=24'h303a50;
                for(i=0;i<8;i=i+1)begin
                    slot=lane*8+i;b=(i==0 && holding[lane]) ? 384 : bottom[slot];
                    if(valid[slot] && head<0 && y>=b-31 && y<=b)begin head=slot;hr=y-(b-31);end
                    if(valid[slot] && is_hold[slot] && body<0 && y>=tail[slot] && y<b-31)begin body=slot;tr=y-tail[slot];end
                end
                if(body>=0)begin
                    padding=tr==0 ? 4 : tr==1 ? 2 : tr<4 ? 1 : 0;
                    if(lx>=18+padding && lx<94-padding)reference_pixel=tr<4 ? bright(lane) : dark(lane);
                end
                if(head>=0 && lx>=18+corner(hr) && lx<94-corner(hr))begin
                    distance=lx>=56 ? lx-56 : 56-lx;
                    white=hr>=28;
                    if(is_hold[head])begin
                        if((hr==13 || hr==16) && lx>=45 && lx<67)white=1;
                        if((hr==14 || hr==15) && lx>=44 && lx<68)white=1;
                    end else if(chevron(hr,distance))white=1;
                    reference_pixel=white ? 24'hffffff : bright(lane);
                end
                if(y==384 || y==385)reference_pixel=24'hffffff;
            end
        end
    endfunction
    integer xx,yy,i,file_id,frame_pixels=0,compared=0;
    reg [9:0] input_x=0,input_y=0,x1=0,y1=0;reg d1=0,save=0;
    wire [23:0] rgb=on ? color : 24'h302418;
    always @(posedge clk)begin d1<=de;x1<=input_x;y1<=input_y;end
    always @(negedge clk)if(d1 && save)begin
        $fwrite(file_id,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);frame_pixels=frame_pixels+1;
        if(x1>=96 && x1<544 && y1>=64 && y1<409)begin
            compared=compared+1;
            if(rgb!==reference_pixel(x1,y1))$fatal(1,"style pixel (%0d,%0d) got=%h expected=%h",x1,y1,rgb,reference_pixel(x1,y1));
        end
    end
    task frame;
        input integer held;
        begin
            @(negedge clk);holding=held ? 4'b0010 : 4'd0;vs=1;
            @(negedge clk);vs=0;repeat(4000)@(negedge clk);
            if(capture || renderer.work!=0 || renderer.hud.phase!=0)$fatal(1,"style snapshot missed vertical blank");
            file_id=$fopen(held ? "prj/log/rhythm_note_style_20261006/held.ppm" : "prj/log/rhythm_note_style_20261006/notes.ppm","wb");
            $fwrite(file_id,"P6\n640 480\n255\n");frame_pixels=0;save=1;
            for(yy=0;yy<480;yy=yy+1)begin
                for(xx=0;xx<640;xx=xx+1)begin @(negedge clk);de=1;input_x=xx;input_y=yy;end
                @(negedge clk);de=0;repeat(160)@(negedge clk);
            end
            repeat(3)@(negedge clk);save=0;$fclose(file_id);
            if(frame_pixels!=307200)$fatal(1,"style frame pixel count %0d",frame_pixels);
        end
    endtask
    initial begin
        for(i=0;i<32;i=i+1)begin valid[i]=0;is_hold[i]=0;bottom[i]=64;tail[i]=64;end
        valid[0]=1;bottom[0]=310;tail[0]=310;
        valid[1]=1;bottom[1]=150;tail[1]=150;
        valid[2]=1;bottom[2]=64;tail[2]=64;
        valid[8]=1;is_hold[8]=1;bottom[8]=340;tail[8]=140;
        // Tap 恰好位于同轨 Hold 尾部，验证共用描述时圆角仍逐像素一致。
        valid[9]=1;bottom[9]=140;tail[9]=140;
        valid[10]=1;bottom[10]=90;tail[10]=90;
        valid[16]=1;bottom[16]=260;tail[16]=260;
        valid[17]=1;bottom[17]=244;tail[17]=244;
        valid[18]=1;bottom[18]=115;tail[18]=115;
        valid[24]=1;bottom[24]=408;tail[24]=408;
        valid[25]=1;bottom[25]=325;tail[25]=325;
        valid[26]=1;is_hold[26]=1;bottom[26]=260;tail[26]=95;
        repeat(4)@(negedge clk);rst=0;repeat(10)@(negedge clk);frame(0);frame(1);
        if(compared!=309120)$fatal(1,"style compared pixel count %0d",compared);
        $display("PASS note style: 309120 exact pixels, four colors, 76x32 rounded heads, chevron/dash, bottom timing, wide Holds, overlap, clipping, held anchor");
        $finish;
    end
    initial begin #60000000;$fatal(1,"note style timeout");end
endmodule
