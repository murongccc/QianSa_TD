// 复用 BMP 目录器的稳定 FAT32 卷，精确读取根目录 GAME.BIN。
// 输出 note_we 为单拍；不可暂停的扇区开始前必须 reserve_ready（至少 64 个空槽）。
module fat32_chart_reader #(
    parameter integer MAX_DIRECTORY_SECTORS = 1024
)(
    input wire clk, input wire rst, input wire enable, input wire cancel,
    input wire volume_valid,
    input wire [31:0] volume_fat_start, volume_data_start, volume_root_cluster,
    input wire [7:0] volume_sectors_per_cluster,
    input wire reserve_ready,
    output reg sd_req, output reg [31:0] sd_addr,
    input wire [7:0] sd_data, input wire sd_valid, input wire sd_done,
    output reg note_we, output reg [63:0] note_data,
    output reg header_valid, output reg [31:0] song_frames,
    output reg [15:0] note_count, output reg [15:0] hold_count,
    output reg signed [31:0] offset_samples,
    output reg [191:0] title, output reg [127:0] difficulty,
    output wire metadata_we,output wire [5:0] metadata_address,output wire [7:0] metadata_data,
    output reg busy, output reg eof, output reg cancelled,
    output reg [3:0] error_code
);
    localparam [3:0] IDLE=0,CALC=1,MULT=2,ADDRESS=3,DIR_REQ=4,DIR_DATA=5,
                     FILE_WAIT=6,FILE_DATA=7,FAT_REQ=8,FAT_DATA=9,FINISHED=10,VERIFY_EOF=11,FAT_CHECK=12;
    reg [3:0] state;
    reg [31:0] fat_start,data_start,cluster,sector;
    // 65535 条记录加头部小于 1 MiB，目录高位必须先拒绝再截位。
    reg [19:0] file_size,file_pos;reg oversized_file;
    reg [19:0] file_last_byte;
    reg [7:0] spc,sector_in_cluster;
    reg [31:0] shift_value,product;
    reg [2:0] multiply_bit;
    reg directory,entry_match,found,dir_end,cancel_pending;
    reg [8:0] byte_pos,fat_offset;
    reg [31:0] next_cluster,entry_cluster,entry_size;
    reg [7:0] entry_first,entry_attr;
    reg [15:0] directory_sectors;
    reg [15:0] count_full,holds_full;reg [19:0] expected_file_size;
    reg [15:0] seen_notes,seen_holds;
    reg length_ok,counts_ok;
    reg header_bad;
    reg [55:0] record;
    reg [31:0] previous_time,last_end[0:3];
    reg [1:0] previous_lane;
    reg [3:0] lane_seen;
    wire [1:0] record_lane=sd_data[1:0];
    wire [31:0] record_start=record[31:0];
    wire [23:0] record_duration=record[55:32];
    reg [32:0] record_end;
    reg signed [33:0] shifted_start,shifted_end;
    wire record_bad = sd_data[7:3]!=0 || (sd_data[2] != (record_duration!=0)) ||
        record_end[32] || shifted_start<0 || shifted_end>=$signed({2'b00,song_frames}) ||
        seen_notes>=count_full[15:0] ||
        (seen_notes!=0 && (record_start<previous_time || (record_start==previous_time && record_lane<=previous_lane))) ||
        (lane_seen[record_lane] && (record_start<last_end[record_lane]));

    assign metadata_we=state==FILE_DATA && sd_valid && file_pos>=24 && file_pos<64 && error_code==0 && !cancel && !cancel_pending;
    assign metadata_address=file_pos[5:0]-6'd24;
    assign metadata_data=sd_data;
    // 接受音符的单拍同时提交到 FIFO 和轻量校验历史，避免取消/解析状态的
    // 长使能链直接驱动四轨 32 位寄存器。下一条记录至少相隔八个字节。
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            seen_notes<=0;seen_holds<=0;previous_time<=0;previous_lane<=0;lane_seen<=0;
        end else if(note_we)begin
            seen_notes<=seen_notes+16'd1;
            if(note_data[58])seen_holds<=seen_holds+16'd1;
            previous_time<=note_data[31:0];previous_lane<=note_data[57:56];
            lane_seen[note_data[57:56]]<=1;
        end
    end

    // 不复位 RAM 内容，lane_seen 保证首次记录不读取旧历史。
    always @(posedge clk)if(!rst && note_we)
        last_end[note_data[57:56]]<=note_data[31:0]+{8'd0,note_data[55:32]};

    always @(posedge clk or posedge rst) begin
        if(rst)begin
            state<=IDLE;sd_req<=0;sd_addr<=0;note_we<=0;note_data<=0;
            header_valid<=0;song_frames<=0;note_count<=0;hold_count<=0;offset_samples<=0;
            title<=0;difficulty<=0;busy<=0;eof<=0;cancelled<=0;error_code<=0;
            fat_start<=0;data_start<=0;cluster<=0;sector<=0;file_size<=0;file_pos<=0;
            file_last_byte<=0;oversized_file<=0;
            spc<=0;sector_in_cluster<=0;shift_value<=0;product<=0;multiply_bit<=0;
            directory<=1;entry_match<=0;found<=0;dir_end<=0;cancel_pending<=0;
            byte_pos<=0;fat_offset<=0;next_cluster<=0;entry_cluster<=0;entry_size<=0;
            entry_first<=0;entry_attr<=0;directory_sectors<=0;
            count_full<=0;holds_full<=0;
            expected_file_size<=0;length_ok<=0;counts_ok<=0;
            header_bad<=0;record<=0;
            record_end<=0;shifted_start<=0;shifted_end<=0;
        end else begin
            note_we<=0;
            // 取消期间不发布数据；整扇区退场后 cancelled 持续有效直到复位。
            if(cancel || cancel_pending)begin
                cancel_pending<=1;
                if(!sd_req || sd_done)begin sd_req<=0;busy<=0;cancelled<=1;state<=FINISHED;end
            end else case(state)
                IDLE:if(enable && volume_valid)begin
                    busy<=1;fat_start<=volume_fat_start;data_start<=volume_data_start;
                    spc<=volume_sectors_per_cluster;cluster<=volume_root_cluster;
                    if(volume_root_cluster<2 || volume_sectors_per_cluster==0 ||
                       (volume_sectors_per_cluster & (volume_sectors_per_cluster-8'd1))!=0)begin
                        busy<=0;error_code<=4'd2;state<=FINISHED;
                    end else state<=CALC;
                end
                // 八拍移位加法，避免新增 spc 乘法器和长组合路径。
                CALC:begin shift_value<=cluster-32'd2;product<=0;multiply_bit<=0;state<=MULT;end
                MULT:begin
                    if(spc[multiply_bit])product<=product+shift_value;
                    shift_value<=shift_value<<1;
                    if(multiply_bit==7)state<=ADDRESS;else multiply_bit<=multiply_bit+3'd1;
                end
                ADDRESS:begin sector<=data_start+product;state<=directory?DIR_REQ:FILE_WAIT;end
                DIR_REQ:begin sd_req<=1;sd_addr<=sector;byte_pos<=0;state<=DIR_DATA;end
                DIR_DATA:begin
                    if(sd_valid)begin
                        byte_pos<=byte_pos+9'd1;
                        case(byte_pos[4:0])
                            0:begin entry_first<=sd_data;entry_match<=sd_data=="G";if(sd_data==0)dir_end<=1;end
                            1:entry_match<=entry_match && sd_data=="A";
                            2:entry_match<=entry_match && sd_data=="M";
                            3:entry_match<=entry_match && sd_data=="E";
                            4,5,6,7:entry_match<=entry_match && sd_data==" ";
                            8:entry_match<=entry_match && sd_data=="B";
                            9:entry_match<=entry_match && sd_data=="I";
                            10:entry_match<=entry_match && sd_data=="N";
                            11:entry_attr<=sd_data;
                            20:entry_cluster[23:16]<=sd_data;
                            21:entry_cluster[31:24]<=sd_data;
                            26:entry_cluster[7:0]<=sd_data;
                            27:entry_cluster[15:8]<=sd_data;
                            28:entry_size[7:0]<=sd_data;
                            29:entry_size[15:8]<=sd_data;
                            30:entry_size[23:16]<=sd_data;
                            31:if(!found && !dir_end && entry_match && entry_first!=8'he5 &&
                                  entry_attr!=8'h0f && (entry_attr & 8'h18)==0)begin
                                found<=1;cluster<=entry_cluster & 32'h0fffffff;
                                file_size<=entry_size[19:0];oversized_file<=sd_data!=0 || entry_size[23:20]!=0;
                            end
                            default:;
                        endcase
                    end
                    if(sd_done)begin
                        sd_req<=0;directory_sectors<=directory_sectors+16'd1;
                        if(found)begin
                            directory<=0;sector_in_cluster<=0;
                            file_last_byte<=file_size-20'd1;
                            if(oversized_file || cluster<2 || cluster>=32'h0ffffff0 || file_size<72)begin error_code<=4'd2;busy<=0;state<=FINISHED;end
                            else state<=CALC;
                        end else if(dir_end || directory_sectors>=MAX_DIRECTORY_SECTORS-1)begin
                            error_code<=4'd1;busy<=0;state<=FINISHED;
                        end else if(sector_in_cluster+8'd1<spc)begin
                            sector_in_cluster<=sector_in_cluster+8'd1;sector<=sector+32'd1;state<=DIR_REQ;
                        end else state<=FAT_REQ;
                    end
                end
                FILE_WAIT:if(reserve_ready)begin sd_req<=1;sd_addr<=sector;state<=FILE_DATA;end
                FILE_DATA:begin
                    if(sd_valid && file_pos<file_size && error_code==0)begin
                        file_pos<=file_pos+20'd1;
                        if(file_pos<64)begin
                            if(file_pos<8)begin
                                // 魔数与固定采样率逐字节校验，不保存两组 32 位移位寄存器。
                                case(file_pos[2:0])
                                    0:if(sd_data!=8'h52)header_bad<=1;
                                    1:if(sd_data!=8'h34)header_bad<=1;
                                    2:if(sd_data!=8'h42)header_bad<=1;
                                    3:if(sd_data!=8'h31)header_bad<=1;
                                    4:if(sd_data!=8'h80)header_bad<=1;
                                    5:if(sd_data!=8'hbb)header_bad<=1;
                                    default:if(sd_data!=0)header_bad<=1;
                                endcase
                            end
                            else if(file_pos<12)song_frames<={sd_data,song_frames[31:8]};
                            else if(file_pos<16)begin
                                if(file_pos<14)count_full<={sd_data,count_full[15:8]};
                                else if(sd_data!=0)header_bad<=1;
                            end
                            else if(file_pos<20)begin
                                if(file_pos<18)holds_full<={sd_data,holds_full[15:8]};
                                else if(sd_data!=0)header_bad<=1;
                            end
                            else if(file_pos<24)offset_samples<={sd_data,offset_samples[31:8]};
                            else if(file_pos<48)title<={sd_data,title[191:8]};
                            else difficulty<={sd_data,difficulty[127:8]};
                            // 头部剩余字节提供多个计算拍，不把长度加法串到最终校验路径。
                            if(file_pos==16)expected_file_size<=20'd64+{1'b0,count_full[15:0],3'd0};
                            if(file_pos==18)length_ok<=file_size==expected_file_size;
                            if(file_pos==20)counts_ok<=count_full!=0 && holds_full<=count_full;
                            if(file_pos==47 && sd_data!=0)header_bad<=1;
                            if(file_pos==63)begin
                                if(song_frames==0 ||
                                   !counts_ok || !length_ok || header_bad || sd_data!=0)error_code<=4'd3;
                                else begin header_valid<=1;note_count<=count_full[15:0];hold_count<=holds_full[15:0];end
                            end
                        end else if(file_pos[2:0]!=7)begin
                            if(file_pos[2:0]<4)record[31:0]<={sd_data,record[31:8]};
                            else record[55:32]<={sd_data,record[55:40]};
                            // 用记录字节采集间隔分开两级加法，再在第七字节判定。
                            // 第四字节到来时头部已稳定，第六字节使用当前持续时间高字节。
                            if(file_pos[2:0]==4)
                                shifted_start<=$signed({2'b00,record_start})+$signed({{2{offset_samples[31]}},offset_samples});
                            if(file_pos[2:0]==6)begin
                                record_end<={1'b0,record_start}+{9'd0,sd_data,record[55:40]};
                                shifted_end<=shifted_start+$signed({10'd0,sd_data,record[55:40]});
                            end
                        end
                        else if(record_bad)error_code<=4'd4;
                        else begin
                            note_data<={sd_data,record};note_we<=1;
                        end
                    end
                    if(sd_done)begin
                        sd_req<=0;
                        if(error_code!=0)begin busy<=0;state<=FINISHED;end
                        else if(file_pos>=file_size || (sd_valid && file_pos==file_last_byte))begin
                            // 等待最后一个 note_we 提交计数，再发布文件结束。
                            state<=VERIFY_EOF;
                        end else if(sector_in_cluster+8'd1<spc)begin
                            sector_in_cluster<=sector_in_cluster+8'd1;sector<=sector+32'd1;state<=FILE_WAIT;
                        end else state<=FAT_REQ;
                    end
                end
                FAT_REQ:begin
                    fat_offset<={cluster[6:0],2'b00};byte_pos<=0;next_cluster<=0;
                    sd_req<=1;sd_addr<=fat_start+(cluster>>7);state<=FAT_DATA;
                end
                FAT_DATA:begin
                    if(sd_valid)begin
                        if(byte_pos[8:2]==fat_offset[8:2])
                            next_cluster<={sd_data,next_cluster[31:8]};
                        byte_pos<=byte_pos+9'd1;
                    end
                    if(sd_done)begin
                        sd_req<=0;state<=FAT_CHECK;
                    end
                end
                // 与末字节同拍结束时，固定移位组装在这一拍已经完整。
                FAT_CHECK:begin
                    if((next_cluster&32'h0fffffff)<2 || (next_cluster&32'h0fffffff)>=32'h0ffffff0)begin
                        busy<=0;error_code<=directory?4'd1:4'd5;state<=FINISHED;
                    end else begin cluster<=next_cluster & 32'h0fffffff;sector_in_cluster<=0;state<=CALC;end
                end
                FINISHED:begin end
                VERIFY_EOF:if(!note_we)begin
                    busy<=0;state<=FINISHED;
                    if(seen_notes!=count_full[15:0] || seen_holds!=holds_full[15:0])error_code<=4'd4;
                    else eof<=1;
                end
                default:begin sd_req<=0;busy<=0;error_code<=4'd2;state<=FINISHED;end
            endcase
        end
    end
endmodule
