`timescale 1ns/1ps
// 共享卷模式下检查流式头解析、奇数 chunk 填充、跨簇边界与错误释放。
module tb_wav_streaming_headers;
reg clk=0,rst=1,sd_valid=0,sd_end=0,volume_valid=1;
reg [7:0] sd_data=0;
reg [31:0] volume_root_cluster=2;
reg [7:0] volume_spc=1;
wire read_request,fifo_we,format_ok,format_error,done;
wire [31:0] read_address,fifo_data;
integer vector_index,byte_index,writes,data_offset,file_length;
always #5 clk=~clk;
fat32_wav_reader #(.USE_SHARED_VOLUME(1)) dut(
    .clk(clk),.rst(rst),.sd_init_done(1'b1),.enable(1'b1),
    .sd_sec_read(read_request),.sd_sec_read_addr(read_address),
    .sd_data(sd_data),.sd_data_valid(sd_valid),.sd_sec_read_end(sd_end),
    .fifo_we(fifo_we),.fifo_din(fifo_data),.fifo_full(1'b0),.audio_read_toggle(1'b0),
    .audio_fifo_level(),.busy(),.done(done),.file_found(),.format_ok(format_ok),.format_error(format_error),
    .volume_valid(volume_valid),.volume_fat_start(32'd100),.volume_data_start(32'd200),
    .volume_root_cluster(volume_root_cluster),.volume_sectors_per_cluster(volume_spc));
always @(posedge clk) if(!rst && fifo_we)begin
    writes=writes+1;
    if(fifo_data!==32'h56781234) $fatal(1,"PCM/chunk boundary data mismatch %h",fifo_data);
end
function [7:0] file_byte;
    input integer offset;
    integer chunk_length;
    begin
        file_byte=0;
        chunk_length=(vector_index==2)?459:3;
        case(offset)
            0:file_byte="R";1:file_byte="I";2,3:file_byte="F";
            8:file_byte="W";9:file_byte="A";10:file_byte="V";11:file_byte="E";
            12:file_byte="f";13:file_byte="m";14:file_byte="t";15:file_byte=" ";
            16:file_byte=16;20:file_byte=1;22:file_byte=2;
            24:file_byte=(vector_index==3)?8'h81:8'h80;25:file_byte=8'hbb;34:file_byte=16;
            default: ;
        endcase
        if(vector_index==1 || vector_index==2)begin
            case(offset)
                36:file_byte="J";37:file_byte="U";38:file_byte="N";39:file_byte="K";
                40:file_byte=chunk_length[7:0];41:file_byte=chunk_length[15:8];
                default: ;
            endcase
        end
        if(offset==data_offset)file_byte="d";
        if(offset==data_offset+1)file_byte="a";
        if(offset==data_offset+2)file_byte="t";
        if(offset==data_offset+3)file_byte="a";
        if(offset==data_offset+4)file_byte=4;
        if(offset==data_offset+8)file_byte=8'h34;
        if(offset==data_offset+9)file_byte=8'h12;
        if(offset==data_offset+10)file_byte=8'h78;
        if(offset==data_offset+11)file_byte=8'h56;
    end
endfunction
task send_sector;
    input [31:0] address;
    integer offset;
    begin
        wait(read_request);
        if(read_address!==address) $fatal(1,"unexpected SD request %0d expected %0d",read_address,address);
        for(byte_index=0;byte_index<512;byte_index=byte_index+1)begin
            @(negedge clk);sd_data=0;
            if(address==200)begin
                case(byte_index)
                    0:sd_data="X";8:sd_data="W";9:sd_data="A";10:sd_data="V";26:sd_data=3;
                    28:sd_data=file_length[7:0];29:sd_data=file_length[15:8];
                    default: ;
                endcase
            end else if(address==100)begin
                if(byte_index==12)sd_data=4;
            end else begin
                offset=(address==201)?byte_index:512+byte_index;
                sd_data=file_byte(offset);
            end
            sd_valid=1;
            @(negedge clk);sd_valid=0;
            repeat(byte_index%3) @(negedge clk);
        end
        @(negedge clk);sd_end=1;
        @(negedge clk);sd_end=0;
    end
endtask
initial begin
    for(vector_index=0;vector_index<4;vector_index=vector_index+1)begin
        @(negedge clk);rst=1;sd_valid=0;sd_end=0;writes=0;
        repeat(3) @(negedge clk);rst=0;
        data_offset=(vector_index==1)?48:(vector_index==2)?504:36;
        file_length=(vector_index==2)?516:80;
        send_sector(200);send_sector(201);
        if(vector_index==2)begin send_sector(100);send_sector(202);end
        repeat(4) @(negedge clk);
        if(vector_index==3)begin
            if(!format_error || writes!=0 || read_request) $fatal(1,"invalid header failed to release shared port");
        end else if(writes!=1 || format_error) $fatal(1,"WAV vector %0d produced %0d frames",vector_index,writes);
        $display("PASS streamed WAV vector %0d",vector_index);
    end
    @(negedge clk);rst=1;volume_valid=0;
    repeat(3) @(negedge clk);rst=0;
    repeat(20) @(negedge clk);
    if(read_request) $fatal(1,"invalid shared volume issued an SD request");
    // 播放重启必须重新锁存稳定卷信息，而不是使用上一轮的根目录地址。
    @(negedge clk);rst=1;volume_valid=1;volume_root_cluster=5;volume_spc=2;
    repeat(3) @(negedge clk);rst=0;
    wait(read_request);
    if(read_address!==32'd206) $fatal(1,"playback restart reused stale volume metadata");
    $display("PASS WAV streamed headers: plain, padded chunk, fragmented boundary, invalid header/volume");
    $finish;
end
initial begin #1000000;$fatal(1,"streamed WAV test timeout");end
endmodule
