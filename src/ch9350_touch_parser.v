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
    output reg [1:0] press_mask, output reg [1:0] release_mask, output reg [7:0] frame_seq,
    output reg [15:0] good_count, output reg [15:0] checksum_error_count,
    output reg [15:0] format_error_count, output reg [15:0] sequence_gap_count,
    output reg [15:0] timeout_count, output reg [15:0] uart_error_count
);
localparam [2:0] HEAD=3'd0, MAGIC=3'd1, COMMAND=3'd2, LENGTH=3'd3, BODY=3'd4, STATUS=3'd5;
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
reg [2:0] state;
reg [TIMEOUT_BITS-1:0] idle_ticks;
reg [6:0] last_body_index, body_index;
reg [7:0] checksum, frame_sequence;
reg identifier_ok, report_id_ok, report_count_ok;
reg [1:0] report_count;
// 状态只需编号、保留位非零标志和按住位，保留所有非法状态的拒绝能力。
reg [5:0] c0_status, c1_status;
reg [15:0] c0_x, c0_y, c1_x, c1_y;
reg extra_nonzero, sequence_known, a_known, b_known;
reg [7:0] last_sequence;
// 在长度字节处计算一次末字节位置，后续序号位置共用下一索引。
wire [6:0] body_next=body_index+7'd1;
wire last_body_byte=body_index==last_body_index;
wire c0_present = report_count!=2'd0;
wire c1_present = report_count==2'd2;
wire report_ok = last_body_index==7'd56 && identifier_ok &&
    report_id_ok && report_count_ok && !extra_nonzero &&
    (!c0_present || !c0_status[1]) && (!c1_present || !c1_status[1]) &&
    (!c1_present || c0_status[5:2]!=c1_status[5:2]) &&
    (c0_present || (c0_status==6'd0 && c0_x==16'd0 && c0_y==16'd0)) &&
    (c1_present || (c1_status==6'd0 && c1_x==16'd0 && c1_y==16'd0));

// 校验错、格式错、正确帧互斥；序号跳变可与后两者同拍发生，独立递增。
wire checksum_increment=state==BODY && last_body_byte && byte_data!=checksum;
wire good_increment=state==BODY && last_body_byte && byte_data==checksum && report_ok;
wire [15:0] report_counter=checksum_increment ? checksum_error_count :
    good_increment ? good_count : format_error_count;
wire [15:0] next_report_count,next_sequence_gap;
touch_counter_increment u_report_increment(.clk(clk),.rst(rst),.count(report_counter),.next_count(next_report_count));
touch_counter_increment #(.USE_DSP(1)) u_gap_increment(.clk(clk),.rst(rst),.count(sequence_gap_count),.next_count(next_sequence_gap));

// 先匹配已知编号，再分配新编号，避免记录换位或释放后压缩造成手指交换。
reg [3:0] next_a_id, next_b_id;
reg next_a_down, next_b_down, next_a_known, next_b_known;
reg [15:0] next_a_x, next_a_y, next_b_x, next_b_y;
reg claim_a, claim_b, used0, used1;
reg [1:0] a_record,b_record;
always @* begin
    next_a_id=a_id; next_b_id=b_id; next_a_known=a_known; next_b_known=b_known;
    a_record=2'd0;b_record=2'd0;
    next_a_down=1'b0; next_b_down=1'b0;
    claim_a=1'b0; claim_b=1'b0; used0=1'b0; used1=1'b0;
    if (c0_present && a_known && c0_status[5:2]==a_id) begin
        next_a_down=c0_status[0]; a_record=2'd1; claim_a=1'b1; used0=1'b1;
    end
    if (c1_present && a_known && c1_status[5:2]==a_id) begin
        next_a_down=c1_status[0]; a_record=2'd2; claim_a=1'b1; used1=1'b1;
    end
    if (c0_present && b_known && c0_status[5:2]==b_id) begin
        next_b_down=c0_status[0]; b_record=2'd1; claim_b=1'b1; used0=1'b1;
    end
    if (c1_present && b_known && c1_status[5:2]==b_id) begin
        next_b_down=c1_status[0]; b_record=2'd2; claim_b=1'b1; used1=1'b1;
    end
    if (c0_present && !used0 && c0_status[0]) begin
        if (!claim_a) begin
            next_a_id=c0_status[5:2]; next_a_down=1'b1; next_a_known=1'b1;
            a_record=2'd1; claim_a=1'b1;
        end else if (!claim_b) begin
            next_b_id=c0_status[5:2]; next_b_down=1'b1; next_b_known=1'b1;
            b_record=2'd1; claim_b=1'b1;
        end
    end
    if (c1_present && !used1 && c1_status[0]) begin
        if (!claim_a) begin
            next_a_id=c1_status[5:2]; next_a_down=1'b1; next_a_known=1'b1;
            a_record=2'd2;
        end else if (!claim_b) begin
            next_b_id=c1_status[5:2]; next_b_down=1'b1; next_b_known=1'b1;
            b_record=2'd2;
        end
    end
    // 只选择一次宽坐标，编号分配逻辑不再重复选择32位数据。
    next_a_x=a_record[1] ? c1_x : c0_x;
    next_a_y=a_record[1] ? c1_y : c0_y;
    next_b_x=b_record[1] ? c1_x : c0_x;
    next_b_y=b_record[1] ? c1_y : c0_y;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=HEAD; idle_ticks<={TIMEOUT_BITS{1'b0}}; last_body_index<=7'd0; body_index<=7'd0;
        checksum<=8'd0; identifier_ok<=1'b0; report_id_ok<=1'b0; report_count_ok<=1'b1; report_count<=2'd0; frame_sequence<=8'd0;
        c0_status<=6'd0; c1_status<=6'd0; c0_x<=16'd0; c0_y<=16'd0; c1_x<=16'd0; c1_y<=16'd0;
        extra_nonzero<=1'b0; sequence_known<=1'b0; last_sequence<=8'd0;
        a_known<=1'b0; b_known<=1'b0; a_id<=4'd0; b_id<=4'd0; a_down<=1'b0; b_down<=1'b0;
        a_x<=16'd0; a_y<=16'd0; b_x<=16'd0; b_y<=16'd0;
        ack_request<=1'b0; update_valid<=1'b0; press_mask<=2'd0; release_mask<=2'd0; frame_seq<=8'd0;
        good_count<=16'd0; checksum_error_count<=16'd0; format_error_count<=16'd0;
        sequence_gap_count<=16'd0; timeout_count<=16'd0; uart_error_count<=16'd0;
    end else begin
        ack_request<=1'b0; update_valid<=1'b0; press_mask<=2'd0; release_mask<=2'd0;
        if (state==HEAD || byte_valid) idle_ticks<={TIMEOUT_BITS{1'b0}};
        else if (idle_ticks!=TIMEOUT_LIMIT) idle_ticks<=idle_ticks+1'b1;
        if (byte_error) begin
            state<=HEAD; idle_ticks<={TIMEOUT_BITS{1'b0}}; uart_error_count<=uart_error_count+16'd1;
        end else if (state!=HEAD && idle_ticks==TIMEOUT_LIMIT && !byte_valid) begin
            state<=HEAD; idle_ticks<={TIMEOUT_BITS{1'b0}}; timeout_count<=timeout_count+16'd1;
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
                        sequence_known<=1'b0; a_known<=1'b0; b_known<=1'b0;
                        if (a_down || b_down) begin
                            a_down<=1'b0; b_down<=1'b0;
                            release_mask<={b_down,a_down}; update_valid<=1'b1;
                        end
                    end
                    else format_error_count<=next_report_count;
                    state<=HEAD;
                end
                LENGTH: begin
                    if (byte_data>=8'd3 && byte_data<=8'd72) begin
                        last_body_index<=byte_data[6:0]-7'd1; body_index<=7'd0; checksum<=8'd0;
                        identifier_ok<=1'b0; report_id_ok<=1'b0; report_count_ok<=1'b1; report_count<=2'd0; frame_sequence<=8'd0;
                        c0_status<=6'd0; c1_status<=6'd0; c0_x<=16'd0; c0_y<=16'd0; c1_x<=16'd0; c1_y<=16'd0;
                        extra_nonzero<=1'b0; state<=BODY;
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
                            if (sequence_known && frame_sequence!=last_sequence+8'd1)
                                sequence_gap_count<=next_sequence_gap;
                            last_sequence<=frame_sequence; sequence_known<=1'b1;
                            if (!report_ok) format_error_count<=next_report_count;
                            else begin
                                a_id<=next_a_id; a_down<=next_a_down; a_known<=next_a_known;
                                b_id<=next_b_id; b_down<=next_b_down; b_known<=next_b_known;
                                // 无匹配记录时用寄存器保持使能，省去宽坐标的第三路反馈选择。
                                if(a_record!=2'd0)begin a_x<=next_a_x;a_y<=next_a_y;end
                                if(b_record!=2'd0)begin b_x<=next_b_x;b_y<=next_b_y;end
                                press_mask<={next_b_down && (!b_down || next_b_id!=b_id), next_a_down && (!a_down || next_a_id!=a_id)};
                                release_mask<={b_down && (!next_b_down || next_b_id!=b_id), a_down && (!next_a_down || next_a_id!=a_id)};
                                frame_seq<=frame_sequence; update_valid<=1'b1; good_count<=next_report_count;
                            end
                        end
                    end else begin
                        body_index<=body_next;
                        if (body_index!=7'd0) checksum<=checksum+byte_data;
                        if (body_next==last_body_index) frame_sequence<=byte_data;
                        else case (body_index)
                            7'd0: identifier_ok<=byte_data==8'h40 || byte_data==8'h41;
                            7'd1: report_id_ok<=byte_data==8'h0d;
                            7'd2: c0_status<={byte_data[7:4],|byte_data[3:1],byte_data[0]};
                            7'd3: c0_x[7:0]<=byte_data;
                            7'd4: c0_x[15:8]<=byte_data;
                            7'd5: c0_y[7:0]<=byte_data;
                            7'd6: c0_y[15:8]<=byte_data;
                            7'd7: c1_status<={byte_data[7:4],|byte_data[3:1],byte_data[0]};
                            7'd8: c1_x[7:0]<=byte_data;
                            7'd9: c1_x[15:8]<=byte_data;
                            7'd10: c1_y[7:0]<=byte_data;
                            7'd11: c1_y[15:8]<=byte_data;
                            7'd54: begin report_count<=byte_data[1:0];report_count_ok<=byte_data<=8'd2;end
                            default: if (body_index>=7'd12 && body_index<=7'd51 && byte_data!=8'd0)
                                extra_nonzero<=1'b1;
                        endcase
                    end
                end
                default: state<=HEAD;
            endcase
        end
    end
end
endmodule
