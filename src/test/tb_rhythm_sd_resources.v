`timescale 1ns/1ps
// 双时钟、真实不可暂停扇区模型；目录先放诱饵 WAV，谱面跨三个碎片簇。
module tb_rhythm_sd_resources;
    reg clk=0,nclk=0,rst=1,enable=0,cancel=0,nready=0,breq=0;
    reg [7:0] data=0;
    reg valid=0,done=0;
    wire req,bvalid,bdone,awe,nvalid,ready,cancelled,aeof,ceof;
    wire [31:0] addr,adata,frames,level;
    wire [63:0] ndata;
    wire [15:0] count,holds;
    wire [3:0] error;
    integer bytes,record_index,consumed=0,audio_count=0,bmp_count=0,cycles=0,scenario=0;
    integer at,which;
    reg [31:0] owner_addr;
    reg [63:0] expected;
    reg [7:0] image[0:1103];
    reg [31:0] value;
    always #5 clk=~clk;
    always #13 nclk=~nclk;
    rhythm_sd_resources #(.REUSE_MEDIA(1)) dut(
        .metadata_address(6'd0),.metadata_data(),
    .game_mode(scenario!=11),.wav_busy(),.wav_done(),.wav_found(),.wav_format_ok(),.wav_format_error(),
    .clk(clk),.note_clk(nclk),.rst(rst),.enable(enable),.cancel(cancel),
        .volume_valid(1'b1),.volume_fat_start(32'd100),.volume_data_start(32'd200),
        .volume_root_cluster(32'd2),.volume_sectors_per_cluster(8'd1),
        .bmp_req(breq),.bmp_addr(32'd999),.bmp_valid(bvalid),.bmp_done(bdone),
        .sd_req(req),.sd_addr(addr),.sd_data(data),.sd_valid(valid),.sd_done(done),
        .audio_fifo_we(awe),.audio_fifo_data(adata),.audio_fifo_full(1'b0),.audio_read_toggle(1'b0),
        .audio_fifo_level(level),.note_ready(nready),.note_valid(nvalid),.note_data(ndata),
        .header_valid(),.song_frames(frames),.note_count(count),.hold_count(holds),
        .offset_samples(),.title(),.difficulty(),.resources_ready(ready),.cancelled(cancelled),
        .audio_eof(aeof),.chart_eof(ceof),.error_code(error));
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
                            word_value=(scenario==12 && entry==1)?32'h100450:scenario==10?512:entry==1?1104:12044;
                            sector_byte=(word_value>>((field-28)*8));
                        end
                        default:;
                    endcase
                    if(scenario==2 && entry==2 && field==0)sector_byte="Y";
                    if(scenario==9 && entry==1 && field==0)sector_byte="Y";
                end
                if(scenario==11 && entry==0)begin
                    case(field)0:sector_byte="G";1:sector_byte="A";2:sector_byte="M";3:sector_byte="E";26:sector_byte=20;default:begin end endcase
                end
                if(scenario==11 && entry==2 && field<8)sector_byte=field==0 ? "X" : " ";
            end else if(address==100)begin
                cluster_number=index/4;
                word_value=32'hffffffff;
                if(cluster_number==3)word_value=scenario==3?32'hffffffff:32'hf0000009;
                if(cluster_number==9)word_value=7;
                if(cluster_number>=20 && cluster_number<43)word_value=32'hf0000000+cluster_number+1;
                sector_byte=word_value>>((index%4)*8);
            end else if(address==201 || address==207 || address==205)begin
                offset=(address==201?0:address==207?512:1024)+index;
                if(offset<1104)sector_byte=image[offset];
                if(scenario==13 && offset==14)sector_byte=1;
                if(scenario==14 && offset==6)sector_byte=1;
                if(scenario==15 && offset==19)sector_byte=1;
                if(scenario==1 && offset==0)sector_byte="X";
                if(scenario==4 && offset==16)sector_byte=11;
                if(scenario==5 && offset==71)sector_byte=8'h08;
                if(scenario==6 && offset>=20 && offset<24)sector_byte=8'hff;
                if(scenario==8 && offset==8)sector_byte=8'hb7;
            end else if(address>=218 && address<=241)begin
                offset=(address-218)*512+index;
                case(offset)
                    0:sector_byte="R";1:sector_byte="I";2,3:sector_byte="F";
                    4:sector_byte=8'h04;5:sector_byte=8'h2f;
                    8:sector_byte="W";9:sector_byte="A";10:sector_byte="V";11:sector_byte="E";
                    12:sector_byte="f";13:sector_byte="m";14:sector_byte="t";15:sector_byte=" ";
                    16:sector_byte=16;20:sector_byte=1;22:sector_byte=2;
                    24:sector_byte=8'h80;25:sector_byte=8'hbb;
                    28:sector_byte=0;29:sector_byte=8'hee;30:sector_byte=2;
                    32:sector_byte=4;34:sector_byte=16;
                    36:sector_byte="d";37:sector_byte="a";38:sector_byte="t";39:sector_byte="a";
                    40:sector_byte=8'he0;41:sector_byte=8'h2e;
                    default:if(offset>=44 && offset<12044)begin
                        case((offset-44)%4)0:sector_byte=8'h34;1:sector_byte=8'h12;2:sector_byte=8'h78;3:sector_byte=8'h56;endcase
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
        wait(req && !rst);@(negedge clk);owner_addr=addr;
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
    always @(posedge clk)if(!rst)begin
        if(awe)begin audio_count=audio_count+1;if(adata!==32'h56781234)$fatal(1,"PCM mismatch");end
        if(bdone)bmp_count=bmp_count+1;
    end
    always @(posedge nclk)if(!rst && nvalid && nready)begin
        expected={8'd0,24'd0,32'd0};
        expected[31:0]=consumed*(scenario==10?1:10);
        expected[55:32]=(consumed%13==0)?(scenario==10?24'd1:24'd5):24'd0;
        expected[63:56]=(consumed%4)|((consumed%13==0)?4:0);
        if(ndata!==expected)$fatal(1,"record %0d mismatch %h expected %h",consumed,ndata,expected);
        consumed=consumed+1;
    end
    task reset_session;
        begin
            @(negedge clk);rst=1;enable=0;cancel=0;nready=0;breq=0;
            repeat(10)@(negedge clk);audio_count=0;consumed=0;
            rst=0;enable=1;
        end
    endtask
    initial begin
        for(at=0;at<1104;at=at+1)image[at]=0;
        image[0]="R";image[1]="4";image[2]="B";image[3]="1";
        image[4]=8'h80;image[5]=8'hbb;
        image[8]=8'hb8;image[9]=8'h0b;image[12]=130;image[16]=10;
        for(record_index=0;record_index<130;record_index=record_index+1)begin
            value=record_index*10;
            for(which=0;which<4;which=which+1)image[64+record_index*8+which]=value>>(which*8);
            image[64+record_index*8+4]=(record_index%13==0)?5:0;
            image[64+record_index*8+7]=(record_index%4)|((record_index%13==0)?4:0);
        end
        reset_session;
        wait(ready);if(count!=130 || holds!=10 || frames!=3000)$fatal(1,"metadata/prebuffer mismatch");
        // 初始不消费，直到缓存水位阻止下一不可暂停扇区；随后随机反压并绕环。
        repeat(15000)@(negedge clk);
        if(dut.chart_used>128 || error!=0)$fatal(1,"FIFO reserve failed");
        fork
            begin
                while(consumed<130)begin @(negedge nclk);cycles=cycles+1;nready=(cycles%9)<5;end
                @(negedge nclk);nready=0;
            end
            begin wait(aeof && ceof);end
        join
        repeat(30)@(negedge clk);
        if(error!=0 || audio_count!=3000 || req)$fatal(1,"single playback/EOF count failed %0d error %0d",audio_count,error);
        // 所有非音频客户端公平，音频结束后 BMP 仍可获准。
        breq=1;wait(bdone);@(negedge clk);breq=0;repeat(5)@(negedge clk);
        cancel=1;wait(cancelled);repeat(5)@(negedge clk);
        scenario=12;reset_session;wait(error!=0);
        if(error!=2)$fatal(1,"oversized chart directory size was truncated");
        cancel=1;wait(cancelled);repeat(4)@(negedge clk);
        $display("PASS fragmented charts, exact GAME.WAV, reserve, dual-clock backpressure, one-shot EOF");
        for(scenario=1;scenario<10;scenario=scenario+1)begin
            reset_session;
            if(scenario==4)nready=1;
            wait(error!=0);
            if(error!==(scenario==1?4'd3:scenario==2?4'd7:scenario==3?4'd5:
                        scenario<=6?4'd4:scenario==7?4'd11:scenario==8?4'd9:4'd1))
                $fatal(1,"wrong error %0d scenario %0d",error,scenario);
            cancel=1;wait(cancelled);repeat(10)@(negedge clk);
            if(req)$fatal(1,"error cancellation failed");
        end
        scenario=0;reset_session;wait(awe);repeat(40)@(negedge clk);cancel=1;
        wait(cancelled);repeat(10)@(negedge clk);
        if(req)$fatal(1,"mid-sector cancellation failed");
        scenario=10;
        image[8]=117;image[9]=0;image[12]=56;image[16]=5;
        for(record_index=0;record_index<56;record_index=record_index+1)begin
            value=record_index;
            image[64+record_index*8+4]=(record_index%13==0)?1:0;
            for(which=0;which<4;which=which+1)image[64+record_index*8+which]=value>>(which*8);
        end
        reset_session;nready=1;
        wait(aeof && ceof && consumed==56);repeat(10)@(negedge clk);
        if(error!=0 || audio_count!=117)$fatal(1,"coincident last-byte/done lost final sample or record");
        $display("PASS exact sector boundary with simultaneous last-byte and done");
        cancel=1;wait(cancelled);scenario=11;reset_session;
        wait(dut.u_wav.file_found);
        if(dut.u_wav.pos<96)$fatal(1,"media selected GAME.WAV instead of ordinary WAV");
        wait(ready);if(nvalid || error || ceof || dut.header_valid)$fatal(1,"media started chart parser");
        cancel=1;wait(cancelled);
        $display("PASS shared media reader excludes GAME.WAV and chart, preserves cancel");
        for(scenario=13;scenario<=15;scenario=scenario+1)begin
            reset_session;wait(error!=0);
            if(error!=3)$fatal(1,"streamed header validation %0d error %0d",scenario,error);
            cancel=1;wait(cancelled);repeat(4)@(negedge clk);
        end
        $display("PASS resource errors, fragmented FAT high bits, cancellation and restart");$finish;
    end
    initial begin
        #10000000;
        $display("timeout scenario=%0d error=%0d consumed=%0d audio=%0d",scenario,error,consumed,audio_count);
        $display("chart_state=%0d wav_state=%0d eof=%b%b req=%b",dut.u_chart.state,dut.u_wav.state,ceof,aeof,req);
        $fatal(1,"resource timeout");
    end
endmodule
