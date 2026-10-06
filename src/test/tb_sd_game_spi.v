`timescale 1ns/1ps
// 实际 SD 控制器/SPI + 当前资源读取器；卡模型仅回放已核对的真实启动扇区。
module tb_sd_game_spi;
    parameter integer USE_REAL_CARD=0;
    parameter integer HIGH_SPEED_DIV=0;
    parameter integer WAV_RETURN_DELAY_NS=0;
    parameter integer EXPECT_E8=0;
    reg clk=0,nclk=0,rst=1;always #5 clk=~clk;always #20 nclk=~nclk;
    wire cs,sck,mosi,init_done,req,valid,done,awe,ready;
    reg miso=1;
    wire [7:0] data;wire [31:0] addr,adata,frames,level;wire [15:0] count,holds;wire [3:0] error;
    reg [7:0] memory[0:12287];integer writes=0,pcm_offset=0,raw_bytes=0,sectors_read=0,bad_raw=0,first_bad=-1;
    reg [7:0] first_header_byte=0;
    rhythm_sd_resources #(.REUSE_MEDIA(1)) resources(
        .clk(clk),.note_clk(nclk),.rst(rst),.enable(init_done),.cancel(1'b0),.game_mode(1'b1),
        .volume_valid(1'b1),.volume_fat_start(32'd2086),.volume_data_start(32'd9640),.volume_root_cluster(32'd2),.volume_sectors_per_cluster(8'd64),
        .metadata_address(6'd0),.metadata_data(),.bmp_req(1'b0),.bmp_addr(32'd0),.bmp_valid(),.bmp_done(),.bmp_data(),.response_busy(),
        .sd_req(req),.sd_addr(addr),.sd_data(data),.sd_valid(valid),.sd_done(done),
        .audio_fifo_we(awe),.audio_fifo_data(adata),.audio_fifo_full(1'b0),.audio_read_toggle(1'b0),.audio_fifo_level(level),
        .note_ready(1'b0),.note_valid(),.note_data(),.header_valid(),.song_frames(frames),.note_count(count),.hold_count(holds),
        .offset_samples(),.title(),.difficulty(),.resources_ready(ready),.cancelled(),.wav_busy(),.wav_done(),.wav_found(),.wav_format_ok(),.wav_format_error(),
        .audio_eof(),.chart_eof(),.error_code(error));
    sd_card_top #(.SPI_HIGH_SPEED_DIV(HIGH_SPEED_DIV)) card_host(.clk(clk),.rst(rst),.SD_nCS(cs),.SD_DCLK(sck),.SD_MOSI(mosi),.SD_MISO(miso),.sd_init_done(init_done),
        .sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(done),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end());
    function integer sector_base;
        input [31:0] address;
        begin
            if(address==9640)sector_base=0;
            else if(address==9641)sector_base=512;
            else if(address>=23848 && address<23850)sector_base=1024+(address-23848)*512;
            else if(address>=23912 && address<23932)sector_base=2048+(address-23912)*512;
            else sector_base=-1;
        end
    endfunction
    // SD SPI mode3: 主机在上升沿采样，卡在下降沿更新。
    reg [7:0] tx_queue[0:1023];reg tx_is_wav[0:1023];integer tx_read=0,tx_write=0,bit_number=0,command_bytes=0;
    reg [7:0] tx_byte=8'hff,rx_byte=0;reg tx_wav=0;
    reg [47:0] command_word=0;reg card_idle=1;
    integer command_id,base,j;reg [31:0] command_lba;
    task push;
        input [7:0] value;input delayed;
        begin
            if(tx_write>=1024)$fatal(1,"card response queue overflow");
            tx_queue[tx_write]=value;tx_is_wav[tx_write]=delayed;tx_write=tx_write+1;
        end
    endtask
    task command;
        begin
            command_id=command_word[45:40];command_lba=command_word[39:8];tx_read=0;tx_write=0;
            push(8'hff,0);
            case(command_id)
                0:begin card_idle=1;push(8'h01,0);end
                8:begin push(8'h01,0);push(8'h00,0);push(8'h00,0);push(8'h01,0);push(8'haa,0);end
                55:push(card_idle ? 8'h01 : 8'h00,0);
                41:begin card_idle=0;push(8'h00,0);end
                16:begin if(command_lba!=512)$fatal(1,"CMD16 block size");push(8'h00,0);end
                17:begin
                    base=sector_base(command_lba);
                    if(base<0)$fatal(1,"CMD17 unexpected LBA %0d",command_lba);
                    if(command_lba!==addr)$fatal(1,"CMD17 address mismatch %0d vs %0d",command_lba,addr);
                    push(8'h00,0);push(8'hff,0);push(8'hfe,0);
                    for(j=0;j<512;j=j+1)push(memory[base+j],command_lba>=23912);
                    // 当前接收器消耗两个 CRC 字节但未校验内容。
                    push(8'h12,0);push(8'h34,0);
                end
                default:$fatal(1,"unexpected SD command %0d",command_id);
            endcase
        end
    endtask
    always @(posedge cs or posedge rst)begin
        tx_read=0;tx_write=0;bit_number=0;command_bytes=0;rx_byte=0;command_word=0;miso<=1;
    end
    always @(negedge sck)if(!cs && !rst)begin
        if(bit_number==0)begin
            if(tx_read<tx_write)begin tx_byte=tx_queue[tx_read];tx_wav=tx_is_wav[tx_read];tx_read=tx_read+1;end
            else begin tx_byte=8'hff;tx_wav=0;end
        end
        if(tx_wav)miso<=#(WAV_RETURN_DELAY_NS) tx_byte[7-bit_number];
        else miso<=tx_byte[7-bit_number];
    end
    always @(posedge sck)if(!cs && !rst)begin
        rx_byte={rx_byte[6:0],mosi};
        if(bit_number==7)begin
            bit_number=0;
            if(command_bytes==0)begin
                if(rx_byte[7:6]==2'b01)begin command_word={40'd0,rx_byte};command_bytes=1;end
            end else begin
                command_word={command_word[39:0],rx_byte};
                if(command_bytes==5)begin command_bytes=0;command();end else command_bytes=command_bytes+1;
            end
        end else bit_number=bit_number+1;
    end
    integer raw_base,at,record_number,field;reg [31:0] word_value;
    always @(posedge clk)if(!rst)begin
        if(valid)begin
            raw_base=sector_base(addr);
            if(raw_base<0 || raw_bytes>=512)$fatal(1,"raw byte framing");
            if(addr==23912 && raw_bytes==0)first_header_byte=data;
            if(data!==memory[raw_base+raw_bytes])begin
                bad_raw=bad_raw+1;
                if(first_bad<0)first_bad=raw_bytes;
                if(!EXPECT_E8)$fatal(1,"SPI byte mismatch LBA=%0d offset=%0d got=%h expected=%h",addr,raw_bytes,data,memory[raw_base+raw_bytes]);
            end
            raw_bytes=raw_bytes+1;
        end
        if(done)begin
            if(raw_bytes!=512)$fatal(1,"sector count %0d",raw_bytes);
            raw_bytes=0;sectors_read=sectors_read+1;
        end
        if(awe)begin
            pcm_offset=2048+44+writes*4;
            if(adata!=={memory[pcm_offset+3],memory[pcm_offset+2],memory[pcm_offset+1],memory[pcm_offset]})$fatal(1,"PCM mismatch %0d",writes);
            writes=writes+1;
        end
    end
    initial begin
        if(USE_REAL_CARD)$readmemh("prj/log/rhythm_e8_diagnosis_20261006/card_startup.hex",memory);
        else begin
            for(at=0;at<12288;at=at+1)memory[at]=0;
            for(at=0;at<16;at=at+1)memory[at*32]=8'he5;
            memory[512]=8'he5;
            for(record_number=0;record_number<2;record_number=record_number+1)begin
                at=544+record_number*32;
                memory[at]="G";memory[at+1]="A";memory[at+2]="M";memory[at+3]="E";
                for(field=4;field<8;field=field+1)memory[at+field]=" ";
                memory[at+8]=record_number ? "W" : "B";memory[at+9]=record_number ? "A" : "I";memory[at+10]=record_number ? "V" : "N";
                memory[at+11]=8'h20;memory[at+26]=record_number ? 225 : 224;
                word_value=record_number ? 12044 : 1104;
                for(field=0;field<4;field=field+1)memory[at+28+field]=word_value>>(field*8);
            end
            memory[1024]="R";memory[1025]="4";memory[1026]="B";memory[1027]="1";
            memory[1028]=8'h80;memory[1029]=8'hbb;memory[1032]=8'hb8;memory[1033]=8'h0b;memory[1036]=130;memory[1040]=10;
            // 预取两扇区含120条完整音符；后续保持反压，启动仅需至少64条。
            for(record_number=0;record_number<120;record_number=record_number+1)begin
                at=1088+record_number*8;word_value=record_number*10;
                for(field=0;field<4;field=field+1)memory[at+field]=word_value>>(field*8);
                memory[at+4]=(record_number%13==0) ? 5 : 0;
                memory[at+7]=(record_number%4)|((record_number%13==0) ? 4 : 0);
            end
            memory[2048]="R";memory[2049]="I";memory[2050]="F";memory[2051]="F";
            memory[2052]=8'h04;memory[2053]=8'h2f;memory[2056]="W";memory[2057]="A";memory[2058]="V";memory[2059]="E";
            memory[2060]="f";memory[2061]="m";memory[2062]="t";memory[2063]=" ";memory[2064]=16;memory[2068]=1;memory[2070]=2;
            memory[2072]=8'h80;memory[2073]=8'hbb;memory[2077]=8'hee;memory[2078]=2;memory[2080]=4;memory[2082]=16;
            memory[2084]="d";memory[2085]="a";memory[2086]="t";memory[2087]="a";memory[2088]=8'he0;memory[2089]=8'h2e;
            for(at=2092;at<12288;at=at+1)case((at-2092)%4)
                0:memory[at]=8'h34;1:memory[at]=8'h12;2:memory[at]=8'h78;3:memory[at]=8'h56;
            endcase
        end
        repeat(5)@(negedge clk);rst=0;
        wait(ready || error!=0);repeat(3)@(negedge clk);
        if(EXPECT_E8)begin
            if(error!=11 || bad_raw==0)$fatal(1,"expected physical-return-delay E8, got error=%0d bad=%0d",error,bad_raw);
            $display("PASS E8H classification with WAV return delay %0d ns: header byte=%h expected=52, first bad offset=%0d, raw mismatches=%0d",WAV_RETURN_DELAY_NS,first_header_byte,first_bad,bad_raw);
        end else begin
            if(error!=0 || !ready || frames!=(USE_REAL_CARD ? 4323421 : 3000) || count!=(USE_REAL_CARD ? 413 : 130) || holds!=(USE_REAL_CARD ? 49 : 10) || level<2048)$fatal(1,"SPI startup result error=%0d ready=%0b",error,ready);
            $display("PASS complete SPI startup delay=%0d ns, spc64, exact root/CMD17/512-byte framing, %0d PCM frames, ready=%0b error=%0d",WAV_RETURN_DELAY_NS,writes,ready,error);
        end
        $finish;
    end
    initial begin #100000000;$fatal(1,"SPI startup timeout");end
endmodule
