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
    reg vs_d,de_d;reg [9:0] x,y;
    wire frame_start=vs && !vs_d;
    wire line_start=de && !de_d,line_end=!de && de_d;
    wire [9:0] px=line_start ? 10'd0 : x;
    reg [2:0] work;
    localparam IDLE=3'd0,COPY=3'd1,SETUP=3'd2,DIVIDE=3'd3,STORE=3'd4,PROGRESS=3'd5,PUBLISH=3'd6;
    reg [4:0] index;
    reg [3:0] hold_snapshot;
    reg signed [32:0] time_snapshot;
    reg [31:0] frames_snapshot;
    // 双缓冲几何，每槽 {有效,Hold,头部 y[9:0],尾部 y[9:0]}。
    reg front_bank;
    reg which_end,negative;
    reg [9:0] head_y;
    reg [16:0] dividend;reg [8:0] quotient,remainder;
    reg [5:0] left;wire [9:0] trial={remainder,dividend[16]};
    wire subtract_ok=trial>=10'd300;
    wire [8:0] quotient_next={quotient[7:0],subtract_ok};
    reg [40:0] progress_remaining;
    wire [40:0] progress_numerator;
    generate if(BLOCK_HUD)begin: dsp_progress
        wire [35:0] low_product,high_product;
        // 用空闲 DSP 分段计算 33 位时间乘 448，减少宽常量加法器。
        EG_LOGIC_MULT #(.INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
            .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
            .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")) low_mul(
            .p(low_product),.a(time_snapshot[17:0]),.b(18'd448),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
            .clk(clk),.rstan(!rst),.rstbn(!rst),.rstpdn(!rst));
        EG_LOGIC_MULT #(.INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
            .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
            .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")) high_mul(
            .p(high_product),.a({3'd0,time_snapshot[32:18]}),.b(18'd448),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
            .clk(clk),.rstan(!rst),.rstbn(!rst),.rstpdn(!rst));
        assign progress_numerator={14'd0,low_product[26:0]}+{high_product[22:0],18'd0};
    end else begin: lut_progress
        assign progress_numerator=({8'd0,time_snapshot}<<9)-({8'd0,time_snapshot}<<6);
    end endgenerate

    wire signed [33:0] difference=$signed({2'd0,(which_end ? view_end : view_start)})-$signed({time_snapshot[32],time_snapshot});
    wire [33:0] magnitude=difference[33] ? -difference : difference;
    wire [9:0] converted_y=negative ? (quotient>9'd24 ? 10'd408 : 10'd384+{1'b0,quotient}) :
        (quotient>9'd320 ? 10'd64 : 10'd384-{1'b0,quotient});
    reg [9:0] progress;
    assign view_index=index;
    assign capture_busy=(work!=IDLE) || (frame_start && enabled);
    // 只读一个几何端口，64 拍完成下一行四轨覆盖计算，行消隐有 160 拍。
    reg row_busy,row_wait;reg [4:0] row_index;reg [9:0] row_y;
    reg [3:0] row_heads,row_bodies,line_heads,line_bodies;
    wire [21:0] row_note;
    wire geo_we=work==STORE && which_end && !frame_start && !rst;
    wire [21:0] geo_data={view_valid,view_start!=view_end,head_y,converted_y};
    generate if(BLOCK_GEOMETRY)begin: block_geometry
        rhythm_block_ram #(.IMPLEMENT("9K"),.WIDTH(22)) ram(.write_clk(clk),.write_enable(geo_we),.write_address({!front_bank,index}),.write_data(geo_data),
            .read_clk(clk),.read_address({front_bank,row_index}),.read_data(row_note));
    end else begin: distributed_geometry
        reg [21:0] geometry[0:63];
        always @(posedge clk)if(geo_we)geometry[{!front_bank,index}]<=geo_data;
        assign row_note=geometry[{front_bank,row_index}];
    end endgenerate
    wire row_head_on=row_note[21] && row_y>=row_note[19:10] && row_y<row_note[19:10]+10'd5;
    wire row_body_on=row_note[21] && row_note[20] && row_y>=row_note[9:0] && row_y<=row_note[19:10];
    reg [3:0] next_heads,next_bodies;
    always @*begin
        next_heads=row_heads;next_bodies=row_bodies;
        if(row_head_on)next_heads[row_index[4:3]]=1'b1;
        if(row_body_on)next_bodies[row_index[4:3]]=1'b1;
    end
    reg [1:0] track;reg in_track;
    reg [9:0] track_left;
    always @*begin
        in_track=px>=10'd96 && px<10'd544;track=0;track_left=96;
        if(px>=10'd432)begin track=3;track_left=432;end
        else if(px>=10'd320)begin track=2;track_left=320;end
        else if(px>=10'd208)begin track=1;track_left=208;end
    end
    wire [9:0] local_x=px-track_left;
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
        .title(title),.difficulty(difficulty),.x(px),.y(y),.text_area(text_area),.rel_x(rel_x),.rel_y(rel_y),.character(character));
    rhythm_font #(.CLOCKED_ROM(BLOCK_HUD)) font(.clk(clk),.character(character),.row(glyph_row),.bits(glyph_bits));
    always @*begin
        overlay=0;color=24'hffffff;
        // 顶部进度条、左上暂停标记，固定判定线与弱轨道边界。
        if(y<10'd3 && px>=96 && px<10'd96+progress)overlay=1;
        if(px>=24 && px<44 && y>=18 && y<38 && (px<30 || px>=38))overlay=1;
        if(in_track && y>=64 && y<409)begin
            if(local_x==0)begin overlay=1;color=24'h303a50;end
            if(line_bodies[track] && local_x>=48 && local_x<64)begin overlay=1;color=24'h276c9c;end
            if(line_heads[track] && local_x>=8 && local_x<104)begin overlay=1;color=24'h72dbff;end
            if(y==384 || y==385)begin overlay=1;color=24'hffffff;end
        end
        if(!BLOCK_HUD && text_area && glyph_col<5 && glyph_row<7 && glyph_bits[3'd4-glyph_col])begin overlay=1;color=24'hffffff;end
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            vs_d<=0;de_d<=0;x<=0;y<=0;frame_enabled<=0;base_pixel_on<=0;base_pixel_rgb<=0;text_area_d<=0;glyph_col_d<=0;glyph_row_d<=0;
            work<=IDLE;index<=0;hold_snapshot<=0;time_snapshot<=0;frames_snapshot<=0;
            which_end<=0;negative<=0;head_y<=0;front_bank<=0;dividend<=0;quotient<=0;remainder<=0;progress_remaining<=0;left<=0;progress<=0;
            row_busy<=0;row_wait<=0;row_index<=0;row_y<=0;row_heads<=0;row_bodies<=0;line_heads<=0;line_bodies<=0;
        end else begin
            vs_d<=vs;de_d<=de;
            if(line_start)x<=1;else if(de)x<=x+10'd1;
            if(line_end && y<479)y<=y+10'd1;
            base_pixel_on<=frame_enabled && de && overlay;base_pixel_rgb<=color;
            text_area_d<=frame_enabled && de && text_area;glyph_col_d<=rel_x[3:1];glyph_row_d<=rel_y[3:1];
            if(frame_start)begin
                y<=0;frame_enabled<=enabled;line_heads<=0;line_bodies<=0;row_busy<=0;
                if(enabled)begin
                    work<=COPY;index<=0;which_end<=0;hold_snapshot<=holding_mask;time_snapshot<=song_time;frames_snapshot<=song_frames;
                end
            end else begin
                case(work)
                    COPY:work<=SETUP;
                    SETUP:begin dividend<=magnitude>34'd96000 ? 17'd96000 : magnitude[16:0];quotient<=0;remainder<=0;left<=17;negative<=difference[33];work<=DIVIDE;end
                    DIVIDE:begin
                        dividend<=dividend<<1;quotient<=quotient_next;left<=left-6'd1;
                        remainder<=subtract_ok ? trial-10'd300 : trial[8:0];
                        if(left==1)work<=STORE;
                    end
                    STORE:if(!which_end)begin head_y<=(index[2:0]==0 && hold_snapshot[index[4:3]]) ? 10'd384 : converted_y;which_end<=1;work<=SETUP;end
                        else begin
                            which_end<=0;if(index==31)work<=PROGRESS;else begin index<=index+5'd1;work<=COPY;end
                        end
                    PROGRESS:begin
                        progress_remaining<=time_snapshot<0 || frames_snapshot==0 ? 41'd0 : progress_numerator;
                        progress<=0;work<=PUBLISH;
                    end
                    PUBLISH:begin
                        if(progress_remaining>={9'd0,frames_snapshot} && progress<10'd448 && frames_snapshot!=0)begin
                            progress_remaining<=progress_remaining-{9'd0,frames_snapshot};progress<=progress+10'd1;
                        end else begin front_bank<=!front_bank;work<=IDLE;
                            row_busy<=1;row_wait<=1;row_index<=0;row_y<=y;row_heads<=0;row_bodies<=0;end
                    end
                    default:work<=IDLE;
                endcase
                if(line_end)begin row_busy<=1;row_wait<=1;row_index<=0;row_y<=y+10'd1;row_heads<=0;row_bodies<=0;end
                else if(row_busy && row_wait)row_wait<=0;
                else if(row_busy)begin
                    row_wait<=1;row_heads<=next_heads;row_bodies<=next_bodies;
                    if(row_index==31)begin row_busy<=0;line_heads<=next_heads;line_bodies<=next_bodies;end else row_index<=row_index+5'd1;
                end
            end
        end
    end
endmodule
