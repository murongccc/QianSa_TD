`timescale 1ns/1ps
// 真实读取器 + 双时钟预取/FIFO + PCM + 会话 + 引擎的闭环，PCM 数据携带帧号。
module tb_rhythm_playback;
    reg clk=0,nclk=0,rst=1,game=1,sw1=1,k2=1,k3=1,k4=1,stall_sd=0;
    always #5 clk=~clk;always #20 nclk=~nclk;
    reg [7:0] data=0;reg valid=0,done=0;
    wire req,awe,nvalid,ready,cancelled,aeof,ceof;
    wire [31:0] addr,adata,frames,level;wire [63:0] ndata;wire [15:0] count,holds;
    wire [3:0] error;
    integer bytes,scenario=0;reg [31:0] owner_addr;reg [7:0] image[0:1103];reg [31:0] value;
    wire capture,frame_active,pixel_on;wire [23:0] pixel_color;
    wire [4:0] view_index;wire view_valid;wire [31:0] view_start,view_end;wire [3:0] holding;
    wire [5:0] metadata_address;wire [7:0] metadata_data;
    wire freeze,active,auto_mode,clear,enable,cancel,engine_reset,engine_run,engine_load,chart_eof;
    reg vs=0;integer frame_cycles=0;
    always @(negedge nclk)begin
        if(rst || clear)begin frame_cycles=0;vs=0;end
        else begin frame_cycles=frame_cycles+1;vs=frame_cycles%8000==0;end
    end
    wire [1:0] mode;wire signed [32:0] time_now;wire [31:0] total_frames;wire [15:0] total_notes;wire signed [31:0] offset;
    wire [3:0] state,error_code;wire nready,judge_done,overflow;
    wire emit,missing,prefetch,re,audio_valid;wire [31:0] sample_index,emitted_count;
    wire [23:0] left_pcm,right_pcm;reg read_toggle=0;
    wire [15:0] p,g,b,m,combo,max_combo;wire [19:0] score;
    reg [31:0] memory[0:4095],fifo_dout=0;
    reg [31:0] written=0,read_count=0;
    wire fifo_empty=written==read_count;wire fifo_full=written-read_count>=4096;
    always @(posedge clk or posedge rst or posedge clear)begin
        if(rst || clear)written<=0;else if(awe)begin
            if(fifo_full)$fatal(1,"PCM FIFO overflow");memory[written[11:0]]<=adata;written<=written+1;
        end
    end
    always @(posedge nclk or posedge rst or posedge clear)begin
        if(rst || clear)begin read_count<=0;read_toggle<=0;fifo_dout<=0;end
        else if(re && !fifo_empty)begin fifo_dout<=memory[read_count[11:0]];read_count<=read_count+1;read_toggle<=!read_toggle;end
    end
    rhythm_sd_resources #(.REUSE_MEDIA(1)) resources(
        .metadata_address(metadata_address),.metadata_data(metadata_data),
    .clk(clk),.note_clk(nclk),.rst(rst || clear),.enable(enable),.cancel(cancel),.game_mode(active),
        .volume_valid(1'b1),.volume_fat_start(32'd100),.volume_data_start(32'd200),.volume_root_cluster(32'd2),.volume_sectors_per_cluster(8'd1),
        .bmp_req(1'b0),.bmp_addr(32'd0),.bmp_valid(),.bmp_done(),.sd_req(req),.sd_addr(addr),.sd_data(data),.sd_valid(valid),.sd_done(done),
        .audio_fifo_we(awe),.audio_fifo_data(adata),.audio_fifo_full(fifo_full),.audio_read_toggle(read_toggle),.audio_fifo_level(level),
        .note_ready(nready && engine_load && !capture),.note_valid(nvalid),.note_data(ndata),.header_valid(),.song_frames(frames),.note_count(count),.hold_count(holds),
        .offset_samples(),.title(),.difficulty(),.resources_ready(ready),.cancelled(cancelled),.wav_busy(),.wav_done(),.wav_found(),.wav_format_ok(),.wav_format_error(),
        .audio_eof(aeof),.chart_eof(ceof),.error_code(error));
    pcm_audio_player #(.PIXEL_CLOCK_HZ(480000),.PREFETCH_PAUSED(1)) player(
        .clk(nclk),.rst(rst || clear),.fifo_dout(fifo_dout),.fifo_empty(fifo_empty),.volume_level_async(3'd4),.playback_mode_async(mode),
        .fifo_re(re),.audio_valid(audio_valid),.left_pcm(left_pcm),.right_pcm(right_pcm),.underrun(),
        .sample_emitted(emit),.sample_missing(missing),.sample_index(sample_index),.emitted_count(emitted_count),.prefetch_ready(prefetch));
    rhythm_session_controller #(.CLOCK_HZ(480000),.DEBOUNCE_MS(1),.PREROLL_SAMPLES(100),.TAIL_SAMPLES(7200)) session(
        .clk(nclk),.rst(rst),.game_switch(game),.run_switch(sw1),.restart_key_n(k2),.pause_key_n(k3),.mode_key_n(k4),
        .media_quiet_async(1'b1),.resources_ready_async(ready),.cancelled_async(cancelled),.audio_eof_async(aeof),.chart_eof_async(ceof),
        .error_async(error),.frames_async(frames),.fifo_level_async(level),.notes_async(count),.offset_async(32'sd0),
        .sample_emitted(emit),.sample_missing(missing),.prefetch_ready(prefetch),.sample_index(sample_index),.emitted_count(emitted_count),
        .judge_done(judge_done),.queue_overflow(overflow),.freeze_media(freeze),.active_game(active),.auto_mode(auto_mode),
        .resource_reset(clear),.resource_enable(enable),.resource_cancel(cancel),.engine_reset(engine_reset),.engine_run(engine_run),.engine_load(engine_load),
        .player_mode(mode),.song_time(time_now),.song_frames(total_frames),.total_notes(total_notes),.chart_offset(offset),.chart_eof(chart_eof),.state(state),.error_code(error_code));
    rhythm_game_engine #(.SHARED_VIEW(1),.BLOCK_QUEUE(1),.SCORE_DSP(1)) engine(.view_capture(capture),.input_mode(2'd2),.clk(nclk),.rst_n(!engine_reset),.run(engine_run && !capture),.song_time(time_now),.chart_offset(offset),
        .total_notes(total_notes),.chart_eof(chart_eof),.note_valid(nvalid && engine_load && !capture),.note_data(ndata),.note_ready(nready),
        .event_valid(1'b0),.event_ready(),.event_time(33'sd0),.press_mask(4'd0),.release_mask(4'd0),.down_mask(4'd0),
        .head_valid(),.head_time(),.holding_mask(holding),.view_index(view_index),.view_valid(view_valid),.view_start(view_start),.view_end(view_end),
        .result_valid(),.result_lane(),.result_grade(),.perfect_count(p),.good_count(g),.bad_count(b),.miss_count(m),
        .combo(combo),.max_combo(max_combo),.score(score),.done(judge_done),.queue_overflow(overflow));
    rhythm_game_renderer #(.COMPACT_LAYOUT(0),.BLOCK_GEOMETRY(1),.STREAM_METADATA(1),.BLOCK_HUD(1)) renderer(
        .pixel_light(),
        .input_down(4'd0),.input_press(4'd0),
        .clk(nclk),.rst(rst || clear),.enabled(active),.de(1'b0),.vs(vs),.song_time(time_now),.song_frames(total_frames),
        .state(state),.error_code(error_code),.auto_mode(auto_mode),.score(score),.combo(combo),.max_combo(max_combo),
        .perfect_count(p),.good_count(g),.bad_count(b),.miss_count(m),.metadata_valid(resources.header_valid),
        .metadata_address(metadata_address),.metadata_data(metadata_data),.title(192'd0),.difficulty(128'd0),
        .view_index(view_index),.view_valid(view_valid),.view_start(view_start),.view_end(view_end),.holding_mask(holding),
        .capture_busy(capture),.frame_enabled(frame_active),.pixel_on(pixel_on),.pixel_rgb(pixel_color));
    function [7:0] sector_byte;
        input [31:0] address;input integer index;
        integer entry,field,offset,cluster_number;
        reg [31:0] word_value;
        begin
            sector_byte=0;
            if(address==200)begin
                entry=index/32;field=index%32;
                if(entry<3)begin
                    case(field)
                        0:sector_byte=entry==0?"X":"G";
                        1:sector_byte=entry==0?" ":"A";
                        2:sector_byte=entry==0?" ":"M";
                        3:sector_byte=entry==0?" ":"E";
                        4,5,6,7:sector_byte=" ";
                        8:sector_byte=entry==1?"B":"W";
                        9:sector_byte=entry==1?"I":"A";
                        10:sector_byte=entry==1?"N":"V";
                        26:sector_byte=entry==1?3:entry==2?20:5;
                        28,29,30,31:begin
                            word_value=entry==1?192:40044;
                            sector_byte=(word_value>>((field-28)*8));
                        end
                        default:;
                    endcase
                    if(scenario==2 && entry==2 && field==0)sector_byte="Y";
                    if(scenario==9 && entry==1 && field==0)sector_byte="Y";
                end
            end else if(address==100)begin
                cluster_number=index/4;
                word_value=32'hffffffff;
                if(cluster_number==3)word_value=scenario==3?32'hffffffff:32'hf0000009;
                if(cluster_number==9)word_value=7;
                if(cluster_number>=20 && cluster_number<98)word_value=32'hf0000000+cluster_number+1;
                sector_byte=word_value>>((index%4)*8);
            end else if(address==201 || address==207 || address==205)begin
                offset=(address==201?0:address==207?512:1024)+index;
                if(offset<1104)sector_byte=image[offset];
                if(scenario==1 && offset==0)sector_byte="X";
                if(scenario==4 && offset==16)sector_byte=11;
                if(scenario==5 && offset==71)sector_byte=8'h08;
                if(scenario==6 && offset>=20 && offset<24)sector_byte=8'hff;
                if(scenario==8 && offset==8)sector_byte=8'hb7;
            end else if(address>=218 && address<=296)begin
                offset=(address-218)*512+index;
                case(offset)
                    0:sector_byte="R";1:sector_byte="I";2,3:sector_byte="F";
                    4:sector_byte=8'h64;5:sector_byte=8'h9c;
                    8:sector_byte="W";9:sector_byte="A";10:sector_byte="V";11:sector_byte="E";
                    12:sector_byte="f";13:sector_byte="m";14:sector_byte="t";15:sector_byte=" ";
                    16:sector_byte=16;20:sector_byte=1;22:sector_byte=2;
                    24:sector_byte=8'h80;25:sector_byte=8'hbb;
                    28:sector_byte=0;29:sector_byte=8'hee;30:sector_byte=2;
                    32:sector_byte=4;34:sector_byte=16;
                    36:sector_byte="d";37:sector_byte="a";38:sector_byte="t";39:sector_byte="a";
                    40:sector_byte=8'h40;41:sector_byte=8'h9c;
                    default:if(offset>=44 && offset<40044)begin
                        case((offset-44)%4)0:sector_byte=(offset-44)/4;1:sector_byte=((offset-44)/4)>>8;2:sector_byte=~((offset-44)/4);3:sector_byte=(~((offset-44)/4))>>8;endcase
                    end
                endcase
                if(scenario==7 && offset==32)sector_byte=8'd8;
                if(scenario==10)begin
                    if(offset==4)sector_byte=8'hf8;
                    if(offset==5)sector_byte=8'h01;
                    if(offset==40)sector_byte=8'hd4;
                    if(offset==41)sector_byte=8'h01;
                end
            end else if(address!=999)$fatal(1,"unexpected/decoy sector %0d",address);
        end
    endfunction
    // 扇区归属被锁定到 done，客户端撤销也不能截断事务。
    initial forever begin
        wait(req && !rst && !clear && !stall_sd);@(negedge clk);owner_addr=addr;
        for(bytes=0;bytes<512;bytes=bytes+1)begin
            if(addr!==owner_addr || !req)$fatal(1,"transaction changed before done");
            data=sector_byte(owner_addr,bytes);valid=1;
            if(scenario==10 && bytes==511)begin
                done=1;@(negedge clk);valid=0;done=0;
            end else begin @(negedge clk);valid=0;repeat(bytes%3)@(negedge clk);end
        end
        if(scenario!=10)begin done=1;@(negedge clk);done=0;end
        wait(!req);@(negedge clk);
    end
    integer audible=0;reg signed [32:0] frozen_time;
    always @(negedge nclk)begin
        if(clear || rst)audible=0;
        else if(emit)begin
            if(sample_index!=audible || left_pcm!=={sample_index[15:0],8'd0} || right_pcm!=={~sample_index[15:0],8'd0})
                $fatal(1,"PCM sequence stale/dropped expected %0d index %0d left %h",audible,sample_index,left_pcm);
            audible=audible+1;
        end
        if(error || error_code || overflow)$fatal(1,"playback error %0d/%0d",error,error_code);
    end
    task wait_state;input [3:0] expected;
        begin while(state!=expected)@(negedge nclk);end
    endtask
    task press;input integer key;
        begin @(negedge nclk);case(key)2:k2=0;3:k3=0;4:k4=0;endcase
            repeat(600)@(negedge nclk);case(key)2:k2=1;3:k3=1;4:k4=1;endcase
            repeat(600)@(negedge nclk);end
    endtask
    integer i;reg [63:0] record;
    initial begin
        for(i=0;i<1104;i=i+1)image[i]=0;
        image[0]="R";image[1]="4";image[2]="B";image[3]="1";
        value=48000;for(i=0;i<4;i=i+1)image[4+i]=value>>(i*8);
        value=10000;for(i=0;i<4;i=i+1)image[8+i]=value>>(i*8);
        image[12]=16;image[16]=2;
        for(i=0;i<16;i=i+1)begin
            record=0;record[31:0]=i*600;record[55:32]=(i%8==0)?1000:0;record[63:56]=(i%4)|((i%8==0)?4:0);
            for(bytes=0;bytes<8;bytes=bytes+1)image[64+i*8+bytes]=record>>(bytes*8);
        end
        repeat(5)@(negedge nclk);rst=0;wait_state(6);while(audible<100)@(negedge nclk);
        press(3);wait_state(7);repeat(20)@(negedge nclk);frozen_time=time_now;
        repeat(100)@(negedge nclk);if(time_now!=frozen_time)$fatal(1,"pause clock");press(3);wait_state(6);
        stall_sd=1;wait_state(8);frozen_time=time_now;repeat(100)@(negedge nclk);
        if(time_now!=frozen_time)$fatal(1,"starvation clock");stall_sd=0;wait_state(6);wait_state(10);
        if(audible!=10000 || m!=16 || p || g || b || score || combo || auto_mode)$fatal(1,"manual idle generated automatic hits");
        press(4);if(state!=10 || auto_mode)$fatal(1,"KEY4 reloaded result");press(2);wait_state(6);while(audible<100)@(negedge nclk);press(2);wait_state(6);wait_state(10);
        if(audible!=10000 || m!=16 || p || g || b || score || combo)$fatal(1,"TEST integrated result");
        sw1=0;wait_state(2);game=0;wait_state(0);wait_state(2);
        if(active || !fifo_empty)$fatal(1,"exit did not clear game");
        $display("PASS integrated SD/PCM/frame sequence, pause, starvation, manual default, ignored KEY4, restart, EOF/result, exit");$finish;
    end
    initial begin #100000000;$fatal(1,"integrated timeout state %0d time %0d PCM %0d",state,time_now,audible);end
endmodule
