// 帧边界取 32 槽快照，串行转换采样时间到像素；行消隐串行形成四轨覆盖掩码。
// 输出与输入像素对齐，内部仅一级寄存，由 video_presentation 完成第二级。
module rhythm_game_renderer #(parameter integer BLOCK_GEOMETRY=0,parameter integer STREAM_METADATA=0,parameter integer BLOCK_HUD=0)(
    input wire clk,input wire rst,input wire enabled,input wire de,input wire vs,
    input wire signed [32:0] song_time,input wire [31:0] song_frames,
    input wire [3:0] state,error_code,input wire auto_mode,
    input wire [19:0] score,input wire [15:0] combo,max_combo,perfect_count,good_count,bad_count,miss_count,
    input wire metadata_valid,input wire [7:0] metadata_data,output wire [5:0] metadata_address,
    input wire [191:0] title,input wire [127:0] difficulty,
    output wire [4:0] view_index,input wire view_valid,input wire [31:0] view_start,view_end,
    input wire [3:0] holding_mask,output wire capture_busy,
    output reg frame_enabled,output wire pixel_on,output wire [23:0] pixel_rgb
);
    reg vs_d,de_d,vs_seen_low;reg [9:0] x;reg [8:0] y;
    // 会话清理不复位板级扫描。VS 持续为高时解除复位不能伪造帧边界；
    // 先观察一次低电平，再接受真实上升沿，期间保持游戏图层关闭。
    wire frame_start=vs_seen_low && vs && !vs_d;
    wire line_start=de && !de_d,line_end=!de && de_d;
    wire [9:0] px=line_start ? 10'd0 : x;
    reg [2:0] work;
    localparam IDLE=3'd0,COPY=3'd1,SETUP=3'd2,DIVIDE=3'd3,STORE=3'd4,PROGRESS=3'd5,PUBLISH=3'd6;
    reg [4:0] index;
    // 每次换槽最多等七拍完整读回；初次快照还要容纳三拍在途写入。
    reg [3:0] copy_wait;
    reg [3:0] hold_snapshot;
    reg signed [32:0] time_snapshot;
    reg [31:0] frames_snapshot;
    // 双缓冲几何，每槽 {有效,Hold,头部 y[9:0],尾部 y[9:0]}。
    reg front_bank;
    reg which_end,negative;
    reg [8:0] head_y;
    reg [16:0] dividend;reg [8:0] quotient,remainder;
    reg [4:0] left;wire [9:0] trial={remainder,dividend[16]};
    wire subtract_ok=trial>=10'd300;
    wire [8:0] quotient_next={quotient[7:0],subtract_ok};
    reg [40:0] progress_remaining;
    wire [40:0] progress_numerator;
    generate if(BLOCK_HUD)begin: dsp_progress
        wire [35:0] product;
        reg [20:0] low_product;
        reg [16:0] high_product;
        wire [34:0] compact_numerator;
        wire [17:0] progress_operand=which_end ? {3'd0,time_snapshot[32:18]} : time_snapshot[17:0];
        // 448=7×64；头/尾 SETUP 拍复用同一 DSP，不增加快照处理周期。
        EG_LOGIC_MULT #(.INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
            .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
            .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")) progress_mul(
            .p(product),.a(progress_operand),.b(18'd7),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
            .clk(clk),.rstan(!rst),.rstbn(!rst),.rstpdn(!rst));
        always @(posedge clk or posedge rst)begin
            if(rst)begin low_product<=0;high_product<=0;end
            else if(!frame_start && work==SETUP && index==0)begin
                if(which_end)high_product<=product[16:0];else low_product<=product[20:0];
            end
        end
        assign compact_numerator={14'd0,low_product}+{high_product,18'd0};
        assign progress_numerator={compact_numerator,6'd0};
    end else begin: lut_progress
        assign progress_numerator=({8'd0,time_snapshot}<<9)-({8'd0,time_snapshot}<<6);
    end endgenerate

    wire signed [33:0] difference=$signed({2'd0,(which_end ? view_end : view_start)})-$signed({time_snapshot[32],time_snapshot});
    // 超出有符号 18 位的时间差直接限幅，近处只构造 18 位绝对值。
    wire difference_fits=(difference[33:17]==17'd0) || (difference[33:17]==17'h1ffff);
    wire [17:0] magnitude=difference[17] ? -difference[17:0] : difference[17:0];
    wire [9:0] converted_y=negative ? (quotient>9'd24 ? 10'd408 : 10'd384+{1'b0,quotient}) :
        (quotient>9'd320 ? 10'd64 : 10'd384-{1'b0,quotient});
    reg [8:0] progress;
    assign view_index=index;
    assign capture_busy=(work!=IDLE) || (frame_start && enabled);
    // 只读一个几何端口，64 拍完成下一行四轨样式计算，行消隐有 160 拍。
    reg row_busy,row_wait;reg [4:0] row_index;reg [8:0] row_y;
    reg [3:0] row_heads,row_bodies,line_heads,line_bodies;
    // 每轨共用六位：头部 {Hold,图案行[4:0]}，长条 {3'd0,尾帽,行[1:0]}。
    // 谱面保证同轨 Hold 不重叠；头部优先时其圆角也覆盖长条尾帽边界。
    // 共用描述避免两份行缓存各保存十二位冗余尾帽信息。
    reg [23:0] row_head_style,line_head_style;
    wire [21:0] row_note;
    wire [19:0] packed_note;
    wire geo_we=work==STORE && which_end && !frame_start && !rst;
    wire [21:0] geo_data={view_valid,view_start!=view_end,1'b0,head_y,converted_y};
    // 转换坐标始终在 64..408，省去两个恒为零的第九位；读端恢复原格式。
    wire [19:0] packed_geometry={geo_data[21:20],geo_data[18:10],geo_data[8:0]};
    assign row_note={packed_note[19:18],1'b0,packed_note[17:9],1'b0,packed_note[8:0]};
    generate if(BLOCK_GEOMETRY)begin: block_geometry
        rhythm_block_ram #(.IMPLEMENT("9K"),.WIDTH(20)) ram(.write_clk(clk),.write_enable(geo_we),.write_address({!front_bank,index}),.write_data(packed_geometry),
            .read_clk(clk),.read_address({front_bank,row_index}),.read_data(packed_note));
    end else begin: distributed_geometry
        reg [19:0] geometry[0:63];
        always @(posedge clk)if(geo_we)geometry[{!front_bank,index}]<=packed_geometry;
        assign packed_note=geometry[{front_bank,row_index}];
    end endgenerate
    // 头部底边沿用原采样时间对应的 y，图案向上展开 32 行，不改变判定时刻。
    wire [9:0] row_head_top=row_note[19:10]-10'd31;
    wire row_head_on=row_note[21] && row_y>=row_head_top && row_y<=row_note[19:10];
    wire row_body_on=row_note[21] && row_note[20] && row_y>=row_note[9:0] && row_y<row_head_top;
    wire [4:0] row_head_position=row_y[4:0]-row_head_top[4:0];
    wire [9:0] row_tail_distance=row_y-row_note[9:0];
    wire [5:0] head_style_data={row_note[20],row_head_position};
    wire [5:0] tail_style_data={3'd0,row_tail_distance<10'd4,row_tail_distance[1:0]};
    reg [3:0] next_heads,next_bodies;
    reg [23:0] next_head_style;
    always @*begin
        next_heads=row_heads;next_bodies=row_bodies;
        next_head_style=row_head_style;
        if(row_head_on && !row_heads[row_index[4:3]])begin
            next_heads[row_index[4:3]]=1'b1;
            case(row_index[4:3])
                0:next_head_style[5:0]=head_style_data;
                1:next_head_style[11:6]=head_style_data;
                2:next_head_style[17:12]=head_style_data;
                3:next_head_style[23:18]=head_style_data;
            endcase
        end
        if(row_body_on && !row_bodies[row_index[4:3]])begin
            next_bodies[row_index[4:3]]=1'b1;
            if(!next_heads[row_index[4:3]])case(row_index[4:3])
                0:next_head_style[5:0]=tail_style_data;
                1:next_head_style[11:6]=tail_style_data;
                2:next_head_style[17:12]=tail_style_data;
                3:next_head_style[23:18]=tail_style_data;
            endcase
        end
    end
    reg [1:0] track;reg in_track;
    reg [9:0] track_left;
    always @*begin
        in_track=px>=10'd96 && px<10'd544;track=0;track_left=96;
        if(px>=10'd432)begin track=3;track_left=432;end
        else if(px>=10'd320)begin track=2;track_left=320;end
        else if(px>=10'd208)begin track=1;track_left=208;end
    end
    // 有效轨道内局部坐标为 0..111，低七位减法保留四条轨道的精确位置。
    wire [6:0] local_x=px[6:0]-track_left[6:0];
    reg [5:0] active_head_style;
    reg [23:0] note_color,body_color;
    always @*begin
        active_head_style=0;note_color=24'hffcf28;body_color=24'h997b18;
        case(track)
            0:begin active_head_style=line_head_style[5:0];end
            1:begin active_head_style=line_head_style[11:6];note_color=24'hff7900;body_color=24'h994900;end
            2:begin active_head_style=line_head_style[17:12];note_color=24'hed2166;body_color=24'h8e143d;end
            3:begin active_head_style=line_head_style[23:18];note_color=24'hce3cf0;body_color=24'h7c2490;end
        endcase
    end
    // 76 像素宽，四像素阶梯圆角；仅小位宽比较，不添加图案 RAM 或乘法器。
    reg [2:0] head_inset,tail_inset;
    always @*begin
        head_inset=0;tail_inset=0;
        case(active_head_style[4:0])
            0,31:head_inset=4;
            1,30:head_inset=2;
            2,3,28,29:head_inset=1;
            default:;
        endcase
        if(active_head_style[2])case(active_head_style[1:0])
            0:tail_inset=4;
            1:tail_inset=2;
            default:tail_inset=1;
        endcase
    end
    wire head_fill=local_x>=7'd18+{4'd0,head_inset} && local_x<7'd94-{4'd0,head_inset};
    wire body_fill=local_x>=7'd18+{4'd0,tail_inset} && local_x<7'd94-{4'd0,tail_inset};
    wire [6:0] mark_distance=local_x<7'd56 ? 7'd56-local_x : local_x-7'd56;
    wire [4:0] arrow_top=5'd17-{1'b0,mark_distance[4:1]};
    wire arrow_mark=mark_distance<=7'd12 && active_head_style[4:0]>=arrow_top && active_head_style[4:0]<arrow_top+5'd3;
    wire dash_mark=(active_head_style[4:0]==5'd13 || active_head_style[4:0]==5'd16) ?
        (local_x>=7'd45 && local_x<7'd67) :
        ((active_head_style[4:0]==5'd14 || active_head_style[4:0]==5'd15) && local_x>=7'd44 && local_x<7'd68);
    wire head_white=active_head_style[4:0]>=5'd28 || (active_head_style[5] ? dash_mark : arrow_mark);
    reg overlay;reg [23:0] color;
    wire [7:0] character;wire [9:0] rel_x,rel_y;wire text_area;
    reg base_pixel_on,text_area_d;reg [23:0] base_pixel_rgb;
    reg [2:0] glyph_col_d,glyph_row_d;
    wire [2:0] glyph_col=BLOCK_HUD ? glyph_col_d : rel_x[3:1];
    wire [2:0] glyph_row=BLOCK_HUD ? glyph_row_d : rel_y[3:1];wire [4:0] glyph_bits;
    wire cached_text=BLOCK_HUD && text_area_d && glyph_col<5 && glyph_row<7 && glyph_bits[3'd4-glyph_col];
    assign pixel_on=base_pixel_on || cached_text;
    assign pixel_rgb=cached_text ? 24'hffffff : base_pixel_rgb;
    rhythm_hud #(.STREAM_METADATA(STREAM_METADATA),.BLOCK_CHARACTERS(BLOCK_HUD)) hud(.metadata_valid(metadata_valid),.metadata_data(metadata_data),.metadata_address(metadata_address),.clk(clk),.rst(rst),.frame_start(frame_start && enabled),.state(state),.error_code(error_code),.auto_mode(auto_mode),
        .score(score),.combo(combo),.max_combo(max_combo),.perfect_count(perfect_count),.good_count(good_count),.bad_count(bad_count),.miss_count(miss_count),
        .title(title),.difficulty(difficulty),.x(px),.y({1'b0,y}),.text_area(text_area),.rel_x(rel_x),.rel_y(rel_y),.character(character));
    rhythm_font #(.CLOCKED_ROM(BLOCK_HUD)) font(.clk(clk),.character(character),.row(glyph_row),.bits(glyph_bits));
    always @*begin
        overlay=0;color=24'hffffff;
        // 顶部进度条、左上暂停标记，固定判定线与弱轨道边界。
        if(y<10'd3 && px>=96 && px<10'd96+progress)overlay=1;
        if(px>=24 && px<44 && y>=18 && y<38 && (px<30 || px>=38))overlay=1;
        if(in_track && y>=64 && y<409)begin
            if(local_x==0)begin overlay=1;color=24'h303a50;end
            if(line_bodies[track] && !line_heads[track] && body_fill)begin
                overlay=1;color=active_head_style[2] ? note_color : body_color;
            end
            if(line_heads[track] && head_fill)begin overlay=1;color=head_white ? 24'hffffff : note_color;end
            if(y==384 || y==385)begin overlay=1;color=24'hffffff;end
        end
        if(!BLOCK_HUD && text_area && glyph_col<5 && glyph_row<7 && glyph_bits[3'd4-glyph_col])begin overlay=1;color=24'hffffff;end
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            vs_d<=0;de_d<=0;vs_seen_low<=0;x<=0;y<=0;frame_enabled<=0;base_pixel_on<=0;base_pixel_rgb<=0;text_area_d<=0;glyph_col_d<=0;glyph_row_d<=0;
            work<=IDLE;index<=0;copy_wait<=0;hold_snapshot<=0;time_snapshot<=0;frames_snapshot<=0;
            which_end<=0;negative<=0;head_y<=0;front_bank<=0;dividend<=0;quotient<=0;remainder<=0;progress_remaining<=0;left<=0;progress<=0;
            row_busy<=0;row_wait<=0;row_index<=0;row_y<=0;row_heads<=0;row_bodies<=0;line_heads<=0;line_bodies<=0;
            row_head_style<=0;line_head_style<=0;
        end else begin
            vs_d<=vs;de_d<=de;
            if(!vs)vs_seen_low<=1'b1;
            if(line_start)x<=1;else if(de)x<=x+10'd1;
            if(line_end && y<9'd479)y<=y+9'd1;
            base_pixel_on<=frame_enabled && de && overlay;base_pixel_rgb<=color;
            text_area_d<=frame_enabled && de && text_area;glyph_col_d<=rel_x[3:1];glyph_row_d<=rel_y[3:1];
            if(frame_start)begin
                y<=0;frame_enabled<=enabled;line_heads<=0;line_bodies<=0;line_head_style<=0;row_busy<=0;
                if(enabled)begin
                    work<=COPY;index<=0;copy_wait<=4'd11;which_end<=0;hold_snapshot<=holding_mask;time_snapshot<=song_time;frames_snapshot<=song_frames;
                end
            end else begin
                case(work)
                    COPY:if(copy_wait!=0)copy_wait<=copy_wait-4'd1;else work<=SETUP;
                    SETUP:begin dividend<=!difference_fits || magnitude>18'd96000 ? 17'd96000 : magnitude[16:0];quotient<=0;remainder<=0;left<=5'd17;negative<=difference[33];work<=DIVIDE;end
                    DIVIDE:begin
                        dividend<=dividend<<1;quotient<=quotient_next;left<=left-5'd1;
                        remainder<=subtract_ok ? trial-10'd300 : trial[8:0];
                        if(left==1)work<=STORE;
                    end
                    STORE:if(!which_end)begin head_y<=(index[2:0]==0 && hold_snapshot[index[4:3]]) ? 10'd384 : converted_y;which_end<=1;work<=SETUP;end
                        else begin
                            which_end<=0;if(index==31)work<=PROGRESS;else begin index<=index+5'd1;copy_wait<=4'd7;work<=COPY;end
                        end
                    PROGRESS:begin
                        progress_remaining<=time_snapshot<0 || frames_snapshot==0 ? 41'd0 : progress_numerator;
                        progress<=0;work<=PUBLISH;
                    end
                    PUBLISH:begin
                        if(progress_remaining>={9'd0,frames_snapshot} && progress<9'd448 && frames_snapshot!=0)begin
                            progress_remaining<=progress_remaining-{9'd0,frames_snapshot};progress<=progress+9'd1;
                        end else begin front_bank<=!front_bank;work<=IDLE;
                            row_busy<=1;row_wait<=1;row_index<=0;row_y<=y;row_heads<=0;row_bodies<=0;row_head_style<=0;end
                    end
                    default:work<=IDLE;
                endcase
                if(line_end)begin row_busy<=1;row_wait<=1;row_index<=0;row_y<=y+9'd1;row_heads<=0;row_bodies<=0;row_head_style<=0;end
                else if(row_busy && row_wait)row_wait<=0;
                else if(row_busy)begin
                    row_wait<=1;row_heads<=next_heads;row_bodies<=next_bodies;row_head_style<=next_head_style;
                    if(row_index==31)begin
                        row_busy<=0;line_heads<=next_heads;line_bodies<=next_bodies;line_head_style<=next_head_style;
                    end else row_index<=row_index+5'd1;
                end
            end
        end
    end
endmodule
