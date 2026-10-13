// 目标屏幕的状态 0 报告解析器。只有整帧校验及格式检查通过，才原子提交触点。
// 坐标及状态位布局来自实测日志；不作为任意 USB HID 设备的通用解析器。
module ch9350_touch_parser #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer FRAME_TIMEOUT_MS = 20
)(
    input wire clk, input wire rst,
    input wire byte_valid, input wire [7:0] byte_data, input wire byte_error,
    output reg ack_request, output reg update_valid,
    output reg [3:0] a_id, output reg a_down, output reg [15:0] a_x, output reg [15:0] a_y,
    output reg [3:0] b_id, output reg b_down, output reg [15:0] b_x, output reg [15:0] b_y,
    output reg [3:0] c_id, output reg c_down, output reg [15:0] c_x, output reg [15:0] c_y,
    output reg all_down,
    output reg [1:0] press_mask, output reg [1:0] release_mask, output reg [7:0] frame_seq,
    output reg [15:0] good_count, output reg [15:0] checksum_error_count,
    output reg [15:0] format_error_count, output reg [15:0] sequence_gap_count,
    output reg [15:0] timeout_count, output reg [15:0] uart_error_count
);
localparam [3:0] HEAD=0, MAGIC=1, COMMAND=2, LENGTH=3, BODY=4, STATUS=5, RETAIN=6, ALLOCATE=7, PUBLISH=8;
function integer counter_width;
    input integer value;
    integer remaining;
    begin
        remaining=value-1;counter_width=0;
        while(remaining>0)begin counter_width=counter_width+1;remaining=remaining>>1;end
        if(counter_width==0)counter_width=1;
    end
endfunction
localparam integer TIMEOUT_BITS=counter_width((CLK_HZ / 1000) * FRAME_TIMEOUT_MS);
localparam [TIMEOUT_BITS-1:0] TIMEOUT_LIMIT = (CLK_HZ / 1000) * FRAME_TIMEOUT_MS - 1;
reg [3:0] state;
reg [TIMEOUT_BITS-1:0] idle_ticks;
reg [6:0] last_body_index, body_index;
reg [7:0] checksum;
reg identifier_ok, report_id_ok, report_count_ok;
reg [3:0] report_count, record_index;
reg [2:0] record_byte;
reg [3:0] record_id, used_records;
reg [7:0] record_status;
reg [23:0] record_coord;
reg [15:0] seen_ids, down_ids, previous_down;
reg [9:0] nonzero_records;
reg records_bad, sequence_known;
reg [7:0] last_sequence;
// 单写单读小型坐标暂存 RAM；无复位，仅有效身份允许读取。忽略身份仅留生命周期位。
wire coordinate_write=state==BODY && byte_valid && !byte_error && body_index>=7'd2 &&
    body_index<=7'd51 && record_byte==3'd4 && (record_status!=0 || record_coord!=0 || byte_data!=0);
wire [6:0] body_next=body_index+7'd1;
wire last_body_byte=body_index==last_body_index;
wire report_ok=last_body_index==7'd56 && identifier_ok && report_id_ok && report_count_ok &&
    !records_bad && used_records==report_count && ((nonzero_records >> report_count)==10'd0);
reg [1:0] slot;
reg [3:0] scan_id;
reg [3:0] next_a_id,next_b_id,next_c_id;
reg next_a_down,next_b_down,next_c_down;
reg [31:0] next_a_coord,next_b_coord,next_c_coord;
wire [3:0] retain_id=slot==0 ? a_id : slot==1 ? b_id : c_id;
wire retain_live=slot==0 ? a_down : slot==1 ? b_down : c_down;
wire [3:0] read_id=state==RETAIN ? retain_id : scan_id;
wire [31:0] read_coord;
// 使用既有器件分布式 RAM 原语，避免512位暂存被综合为触发器/宽多路网络。
EG_LOGIC_DRAM #(.DATA_WIDTH_W(32),.DATA_WIDTH_R(32),.ADDR_WIDTH_W(4),.ADDR_WIDTH_R(4),
    .DATA_DEPTH_W(16),.DATA_DEPTH_R(16)) u_coordinates(
    .di({byte_data,record_coord}),.waddr(record_id),.we(coordinate_write),.wclk(clk),.raddr(read_id),.do(read_coord));
wire fresh=down_ids[scan_id] && !previous_down[scan_id];
// 校验错、格式错、正确帧互斥；序号跳变可与后两者同拍发生，独立递增。
wire checksum_increment=state==BODY && last_body_byte && byte_data!=checksum;
wire good_increment=state==BODY && last_body_byte && byte_data==checksum && report_ok;
wire [15:0] report_counter=checksum_increment ? checksum_error_count :
    good_increment ? good_count : format_error_count;
wire [15:0] next_report_count,next_sequence_gap;
touch_counter_increment u_report_increment(.clk(clk),.rst(rst),.count(report_counter),.next_count(next_report_count));
touch_counter_increment #(.USE_DSP(1)) u_gap_increment(.clk(clk),.rst(rst),.count(sequence_gap_count),.next_count(next_sequence_gap));

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=HEAD; idle_ticks<={TIMEOUT_BITS{1'b0}}; last_body_index<=7'd0; body_index<=7'd0;
        checksum<=8'd0; identifier_ok<=1'b0; report_id_ok<=1'b0; report_count_ok<=1'b1; report_count<=4'd0;
        record_index<=0;record_byte<=0;record_id<=0;record_coord<=0;used_records<=0;record_status<=0;
        seen_ids<=0;down_ids<=0;previous_down<=0;nonzero_records<=0;records_bad<=0;
        sequence_known<=0;last_sequence<=0;slot<=0;scan_id<=0;
        next_a_id<=0;next_b_id<=0;next_c_id<=0;
        next_a_down<=0;next_b_down<=0;next_c_down<=0;
        next_a_coord<=0;next_b_coord<=0;next_c_coord<=0;
        a_id<=0;b_id<=0;c_id<=0;a_down<=0;b_down<=0;c_down<=0;all_down<=0;
        a_x<=0;a_y<=0;b_x<=0;b_y<=0;c_x<=0;c_y<=0;
        ack_request<=1'b0; update_valid<=1'b0; press_mask<=2'd0; release_mask<=2'd0; frame_seq<=8'd0;
        good_count<=16'd0; checksum_error_count<=16'd0; format_error_count<=16'd0;
        sequence_gap_count<=16'd0; timeout_count<=16'd0; uart_error_count<=16'd0;
    end else begin
        ack_request<=1'b0; update_valid<=1'b0; press_mask<=2'd0; release_mask<=2'd0;
        if (state==HEAD || state>=RETAIN || byte_valid) idle_ticks<={TIMEOUT_BITS{1'b0}};
        else if (idle_ticks!=TIMEOUT_LIMIT) idle_ticks<=idle_ticks+1'b1;
        if (byte_error) begin
            state<=HEAD; idle_ticks<={TIMEOUT_BITS{1'b0}}; uart_error_count<=uart_error_count+16'd1;
        end else if (state!=HEAD && state<RETAIN && idle_ticks==TIMEOUT_LIMIT && !byte_valid) begin
            state<=HEAD; idle_ticks<={TIMEOUT_BITS{1'b0}}; timeout_count<=timeout_count+16'd1;
        end else if(state==RETAIN)begin
            // 先释放消失/松开身份，再按编号升序分配，报告记录排列不影响优先级。
            case(slot)
                0:begin next_a_id<=a_id;next_a_down<=retain_live && down_ids[retain_id];
                    next_a_coord<=seen_ids[retain_id] ? read_coord : {a_y,a_x};end
                1:begin next_b_id<=b_id;next_b_down<=retain_live && down_ids[retain_id];
                    next_b_coord<=seen_ids[retain_id] ? read_coord : {b_y,b_x};end
                2:begin next_c_id<=c_id;next_c_down<=retain_live && down_ids[retain_id];
                    next_c_coord<=seen_ids[retain_id] ? read_coord : {c_y,c_x};end
                default: state<=HEAD;
            endcase
            if(slot==2)begin state<=ALLOCATE;scan_id<=0;end else slot<=slot+1'b1;
        end else if(state==ALLOCATE)begin
            if(fresh)begin
                if(!next_a_down)begin next_a_id<=scan_id;next_a_down<=1;next_a_coord<=read_coord;end
                else if(!next_b_down)begin next_b_id<=scan_id;next_b_down<=1;next_b_coord<=read_coord;end
                else if(!next_c_down)begin next_c_id<=scan_id;next_c_down<=1;next_c_coord<=read_coord;end
            end
            if(scan_id==15)state<=PUBLISH;else scan_id<=scan_id+1'b1;
        end else if(state==PUBLISH)begin
            a_id<=next_a_id;b_id<=next_b_id;c_id<=next_c_id;
            a_down<=next_a_down;b_down<=next_b_down;c_down<=next_c_down;
            {a_y,a_x}<=next_a_coord;{b_y,b_x}<=next_b_coord;{c_y,c_x}<=next_c_coord;
            all_down<=|down_ids;previous_down<=down_ids;
            press_mask<={next_b_down && (!b_down || next_b_id!=b_id),next_a_down && (!a_down || next_a_id!=a_id)};
            release_mask<={b_down && (!next_b_down || next_b_id!=b_id),a_down && (!next_a_down || next_a_id!=a_id)};
            update_valid<=1;state<=HEAD;
        end else if (byte_valid) begin
            case (state)
                HEAD: if (byte_data==8'h57) state<=MAGIC;
                MAGIC: if (byte_data==8'hab) state<=COMMAND;
                    else if (byte_data!=8'h57) state<=HEAD;
                COMMAND: begin
                    if (byte_data==8'h88) state<=LENGTH;
                    else if (byte_data==8'h82) state<=STATUS;
                    else begin
                        state<=byte_data==8'h57 ? MAGIC : HEAD;
                    end
                end
                STATUS: begin
                    if (byte_data[7:4]==4'ha) begin
                        ack_request<=1'b1;
                        // 状态 0 请求常见于模块重新上电，旧触点不得跨重连保留。
                        sequence_known<=1'b0; previous_down<=0;all_down<=0;
                        if (all_down) begin
                            a_down<=1'b0; b_down<=1'b0;c_down<=1'b0;
                            release_mask<={b_down,a_down}; update_valid<=1'b1;
                        end
                    end
                    else format_error_count<=next_report_count;
                    state<=HEAD;
                end
                LENGTH: begin
                    if (byte_data>=8'd3 && byte_data<=8'd72) begin
                        last_body_index<=byte_data[6:0]-7'd1; body_index<=7'd0; checksum<=8'd0;
                        identifier_ok<=1'b0; report_id_ok<=1'b0; report_count_ok<=1'b1; report_count<=4'd0;
                        record_index<=0;record_byte<=0;record_id<=0;record_coord<=0;used_records<=0;record_status<=0;
                        seen_ids<=0;down_ids<=0;nonzero_records<=0;records_bad<=0;state<=BODY;
                    end else begin
                        format_error_count<=next_report_count;
                        state<=byte_data==8'h57 ? MAGIC : HEAD;
                    end
                end
                BODY: begin
                    if (last_body_byte) begin
                        state<=HEAD;
                        if (byte_data!=checksum) checksum_error_count<=next_report_count;
                        else begin
                            if (sequence_known && frame_seq!=last_sequence+8'd1)
                                sequence_gap_count<=next_sequence_gap;
                            last_sequence<=frame_seq; sequence_known<=1'b1;
                            if (!report_ok) format_error_count<=next_report_count;
                            else begin
                                slot<=0;state<=RETAIN;good_count<=next_report_count;
                            end
                        end
                    end else begin
                        body_index<=body_next;
                        if (body_index!=7'd0) checksum<=checksum+byte_data;
                        // frame_seq 是带 update_valid 的事件载荷；在校验和前一字节
                        // 直接暂存序号，错误帧不会产生 update_valid，因此诊断端不会采样。
                        if (body_next==last_body_index) frame_seq<=byte_data;
                        else if(body_index>=7'd2 && body_index<=7'd51)begin
                            if(byte_data!=0)nonzero_records[record_index]<=1;
                            case(record_byte)
                                0:begin
                                    record_id<=byte_data[7:4];
                                    record_status<=byte_data;
                                end
                                1:record_coord[7:0]<=byte_data;
                                2:record_coord[15:8]<=byte_data;
                                3:record_coord[23:16]<=byte_data;
                                4:begin
                                    if(record_status!=0 || record_coord!=0 || byte_data!=0)begin
                                        used_records<=used_records+1'b1;
                                        if(seen_ids[record_id] || |record_status[3:1])records_bad<=1;
                                        seen_ids[record_id]<=1;down_ids[record_id]<=record_status[0];
                                    end
                                    record_index<=record_index+1'b1;
                                end
                                default:records_bad<=1;
                            endcase
                            if(record_byte==4)record_byte<=0;else record_byte<=record_byte+1'b1;
                        end else case(body_index)
                            0:identifier_ok<=byte_data==8'h40 || byte_data==8'h41;
                            1:report_id_ok<=byte_data==8'h0d;
                            54:begin report_count<=byte_data[3:0];report_count_ok<=byte_data<=8'd10;end
                            default:begin end
                        endcase
                    end
                end
                default: state<=HEAD;
            endcase
        end
    end
end
endmodule
