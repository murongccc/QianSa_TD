`timescale 1ns/1ps
// 规范头、全部固定字段、长度高位、碎片、循环/EOF 及整扇区错误释放。
module tb_wav_canonical_headers;
reg clk=0,rst=1,sd_valid=0,sd_end=0,volume_valid=1,game_mode=0;
reg [7:0] sd_data=0;
reg [31:0] volume_root_cluster=2;
reg [7:0] volume_spc=1;
wire read_request,fifo_we,format_ok,format_error,done,stream_eof,frames_valid;
wire [31:0] read_address,fifo_data,song_frames;
wire [2:0] format_detail;
integer vector_index,byte_index,writes,mode,field_index,checks=0;
reg [31:0] file_length;
integer bad_field=-1;
reg saw_format;
always #5 clk=~clk;
fat32_wav_reader #(.USE_SHARED_VOLUME(1),.ENABLE_GAME(1)) dut(
    .game_mode(game_mode),.cancel(1'b0),.song_frames(song_frames),.song_frames_valid(frames_valid),
    .stream_eof(stream_eof),.cancelled(),.clk(clk),.rst(rst),.sd_init_done(1'b1),.enable(1'b1),
    .sd_sec_read(read_request),.sd_sec_read_addr(read_address),
    .sd_data(sd_data),.sd_data_valid(sd_valid),.sd_sec_read_end(sd_end),
    .fifo_we(fifo_we),.fifo_din(fifo_data),.fifo_full(1'b0),.audio_read_toggle(1'b0),
    .audio_fifo_level(),.busy(),.done(done),.file_found(),.format_ok(format_ok),.format_error(format_error),.format_error_detail(format_detail),
    .volume_valid(volume_valid),.volume_fat_start(32'd100),.volume_data_start(32'd200),
    .volume_root_cluster(volume_root_cluster),.volume_sectors_per_cluster(volume_spc));
always @(posedge clk) if(!rst)begin
    if(format_ok)saw_format=1;
    if(fifo_we)begin
        writes=writes+1;
        if(fifo_data!==32'h56781234)$fatal(1,"PCM byte order mismatch %h",fifo_data);
    end
end
function [7:0] file_byte;
    input integer offset;
    integer data_length,riff_length;
    begin
        data_length=file_length-44;riff_length=file_length-8;file_byte=0;
        if(vector_index==6)data_length=data_length+4;
        if(vector_index==7)riff_length=riff_length+4;
        if(vector_index==11)data_length=0;
        if(vector_index==13)data_length=4;
        case(offset)
            0:file_byte="R";1:file_byte="I";2,3:file_byte="F";
            8:file_byte="W";9:file_byte="A";10:file_byte="V";11:file_byte="E";
            12:file_byte="f";13:file_byte="m";14:file_byte="t";15:file_byte=" ";
            16:file_byte=16;20:file_byte=1;22:file_byte=2;
            24:file_byte=8'h80;25:file_byte=8'hbb;
            29:file_byte=8'hee;30:file_byte=2;32:file_byte=4;34:file_byte=16;
            36:file_byte="d";37:file_byte="a";38:file_byte="t";39:file_byte="a";
            default: ;
        endcase
        if(offset>=4 && offset<=7)file_byte=riff_length>>((offset-4)*8);
        if(offset>=40 && offset<=43)file_byte=data_length>>((offset-40)*8);
        if(offset>=44 && offset<file_length)case((offset-44)%4)
            0:file_byte=8'h34;1:file_byte=8'h12;2:file_byte=8'h78;3:file_byte=8'h56;
        endcase
        if(vector_index==4 || vector_index==5)case(offset)
            36:file_byte="J";37:file_byte="U";38:file_byte="N";39:file_byte="K";
            default: ;
        endcase
        if(vector_index==8 && offset==43)file_byte=1;
        if(vector_index==9 && offset==7)file_byte=1;
        if(vector_index==14 && offset==16)file_byte=18;
        if(offset==bad_field)file_byte=file_byte^8'h01;
    end
endfunction
task send_sector;
    input [31:0] address;
    integer offset;
    begin
        wait(read_request);
        if(read_address!==address)$fatal(1,"request %0d expected %0d",read_address,address);
        for(byte_index=0;byte_index<512;byte_index=byte_index+1)begin
            @(negedge clk);sd_data=0;
            if(address==200)begin
                case(byte_index)
                    0:sd_data="G";1:sd_data="A";2:sd_data="M";3:sd_data="E";
                    4,5,6,7:sd_data=" ";8:sd_data="W";9:sd_data="A";10:sd_data="V";
                    26:sd_data=vector_index==17 ? 0 : 3;
                    default: ;
                endcase
                if(byte_index>=28 && byte_index<=31)sd_data=file_length>>((byte_index-28)*8);
            end else if(address==100)begin
                if(byte_index==12)sd_data=(vector_index==3)?8'hff:8'd4;
                if(vector_index==3 && byte_index>=13 && byte_index<=15)sd_data=8'hff;
            end else begin
                offset=(address==201)?byte_index:512+byte_index;
                sd_data=file_byte(offset);
            end
            sd_valid=1;
            // 长度 512 的向量在最后一个 PCM 字节同拍结束扇区。
            if(vector_index==1 && byte_index==511)sd_end=1;
            @(negedge clk);sd_valid=0;sd_end=0;
            repeat(byte_index%3)@(negedge clk);
        end
        if(vector_index!=1)begin
            @(negedge clk);sd_end=1;
            @(negedge clk);sd_end=0;
        end
    end
endtask
task run_vector;
    input integer which;
    begin
        vector_index=which;file_length=48;
        if(which==1)file_length=512;
        if(which==2 || which==3)file_length=516;
        if(which==4)file_length=64;
        if(which==5)file_length=1036;
        if(which==10)file_length=49;
        if(which==12)file_length=44;
        if(which==13)file_length=60;
        if(which==15)file_length=32'h01000030;
        if(which==16)file_length=32'hfffffffc;
        @(negedge clk);rst=1;sd_valid=0;sd_end=0;writes=0;saw_format=0;
        repeat(3)@(negedge clk);rst=0;
        send_sector(200);
        if(which!=12 && which!=17)send_sector(201);
        if(which==2 || which==3)begin
            send_sector(100);
            if(which==2)send_sector(202);
        end
        repeat(6)@(negedge clk);
        if((which<=2 || which==15 || which==16) && bad_field<0)begin
            if(format_error || writes!=((which>=15)?117:(file_length-44)/4) || !saw_format)
                $fatal(1,"valid WAV mode=%0d vector=%0d writes=%0d",mode,which,writes);
            if(game_mode && (!frames_valid || song_frames!=(file_length-44)/4))
                $fatal(1,"game full-width length mismatch");
            if(game_mode && which<15 && (!stream_eof || read_request))
                $fatal(1,"game EOF/length mismatch");
            if(which>=15 && stream_eof)$fatal(1,"large file ended after first sector");
            if(!game_mode && which==0)begin
                send_sector(201);repeat(6)@(negedge clk);
                if(writes!=2 || format_error)$fatal(1,"media loop did not revalidate/replay WAV");
            end
        end else begin
            if(format_detail!==((which==12 || which==17) ? 3'd4 : which==3 ? 3'd3 :
                bad_field>=0 ? (((bad_field>=4 && bad_field<=7) || bad_field>=40) ? 3'd2 : 3'd1) :
                (which==4 || which==5 || which==14) ? 3'd1 : 3'd2))
                $fatal(1,"wrong WAV detail mode=%0d vector=%0d field=%0d detail=%0d",mode,which,bad_field,format_detail);
            if(!format_error || read_request || (which!=3 && writes!=0))
                $fatal(1,"bad WAV mode=%0d vector=%0d field=%0d emitted=%0d",mode,which,bad_field,writes);
            if(which==3 && writes!=117)$fatal(1,"truncated chain changed valid prefix");
            if(stream_eof)$fatal(1,"invalid WAV reported successful EOF");
            repeat(20)@(negedge clk);
            if(read_request)$fatal(1,"invalid WAV restarted SD reads");
        end
        checks=checks+1;
    end
endtask
initial begin
    for(mode=0;mode<2;mode=mode+1)begin
        game_mode=mode;
        for(vector_index=0;vector_index<18;vector_index=vector_index+1)run_vector(vector_index);
        // 44 个头字节各自独立注入错误，包括两个长度的全部高位。
        for(field_index=0;field_index<44;field_index=field_index+1)begin
            bad_field=field_index;run_vector(0);
        end
        bad_field=-1;
    end
    @(negedge clk);rst=1;volume_valid=0;
    repeat(3)@(negedge clk);rst=0;
    repeat(20)@(negedge clk);
    if(read_request)$fatal(1,"invalid shared volume issued SD request");
    @(negedge clk);rst=1;volume_valid=1;volume_root_cluster=5;volume_spc=2;
    repeat(3)@(negedge clk);rst=0;
    wait(read_request);
    if(read_address!==32'd206)$fatal(1,"restart reused stale volume metadata");
    $display("PASS canonical WAV: %0d vectors, media/game, fixed fields, lengths, fragments, release, loop/EOF",checks);
    $finish;
end
initial begin #10000000;$fatal(1,"canonical WAV timeout vector=%0d field=%0d addr=%0d",vector_index,bad_field,read_address);end
endmodule
