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
localparam [31:0] TIMEOUT_LIMIT = (CLK_HZ / 1000) * FRAME_TIMEOUT_MS - 1;
reg [2:0] state;
reg [31:0] idle_ticks;
reg [6:0] frame_length, body_index;
reg [7:0] checksum, identifier, report_id, report_count, frame_sequence;
reg [7:0] c0_status, c1_status;
reg [15:0] c0_x, c0_y, c1_x, c1_y;
reg extra_nonzero, sequence_known, a_known, b_known;
reg [7:0] last_sequence;

wire c0_present = report_count!=8'd0;
wire c1_present = report_count==8'd2;
wire report_ok = frame_length==7'd57 && (identifier==8'h40 || identifier==8'h41) &&
    report_id==8'h0d && report_count<=8'd2 && !extra_nonzero &&
    (!c0_present || c0_status[3:1]==3'd0) && (!c1_present || c1_status[3:1]==3'd0) &&
    (!c1_present || c0_status[7:4]!=c1_status[7:4]) &&
    (c0_present || (c0_status==8'd0 && c0_x==16'd0 && c0_y==16'd0)) &&
    (c1_present || (c1_status==8'd0 && c1_x==16'd0 && c1_y==16'd0));

// 先匹配已知编号，再分配新编号，避免记录换位或释放后压缩造成手指交换。
reg [3:0] next_a_id, next_b_id;
reg next_a_down, next_b_down, next_a_known, next_b_known;
reg [15:0] next_a_x, next_a_y, next_b_x, next_b_y;
reg claim_a, claim_b, used0, used1;
always @* begin
    next_a_id=a_id; next_b_id=b_id; next_a_known=a_known; next_b_known=b_known;
    next_a_x=a_x; next_a_y=a_y; next_b_x=b_x; next_b_y=b_y;
    next_a_down=1'b0; next_b_down=1'b0;
    claim_a=1'b0; claim_b=1'b0; used0=1'b0; used1=1'b0;
    if (c0_present && a_known && c0_status[7:4]==a_id) begin
        next_a_down=c0_status[0]; next_a_x=c0_x; next_a_y=c0_y; claim_a=1'b1; used0=1'b1;
    end
    if (c1_present && a_known && c1_status[7:4]==a_id) begin
        next_a_down=c1_status[0]; next_a_x=c1_x; next_a_y=c1_y; claim_a=1'b1; used1=1'b1;
    end
    if (c0_present && b_known && c0_status[7:4]==b_id) begin
        next_b_down=c0_status[0]; next_b_x=c0_x; next_b_y=c0_y; claim_b=1'b1; used0=1'b1;
    end
    if (c1_present && b_known && c1_status[7:4]==b_id) begin
        next_b_down=c1_status[0]; next_b_x=c1_x; next_b_y=c1_y; claim_b=1'b1; used1=1'b1;
    end
    if (c0_present && !used0 && c0_status[0]) begin
        if (!claim_a) begin
            next_a_id=c0_status[7:4]; next_a_down=1'b1; next_a_known=1'b1;
            next_a_x=c0_x; next_a_y=c0_y; claim_a=1'b1;
        end else if (!claim_b) begin
            next_b_id=c0_status[7:4]; next_b_down=1'b1; next_b_known=1'b1;
            next_b_x=c0_x; next_b_y=c0_y; claim_b=1'b1;
        end
    end
    if (c1_present && !used1 && c1_status[0]) begin
        if (!claim_a) begin
            next_a_id=c1_status[7:4]; next_a_down=1'b1; next_a_known=1'b1;
            next_a_x=c1_x; next_a_y=c1_y;
        end else if (!claim_b) begin
            next_b_id=c1_status[7:4]; next_b_down=1'b1; next_b_known=1'b1;
            next_b_x=c1_x; next_b_y=c1_y;
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=HEAD; idle_ticks<=32'd0; frame_length<=7'd0; body_index<=7'd0;
        checksum<=8'd0; identifier<=8'd0; report_id<=8'd0; report_count<=8'd0; frame_sequence<=8'd0;
        c0_status<=8'd0; c1_status<=8'd0; c0_x<=16'd0; c0_y<=16'd0; c1_x<=16'd0; c1_y<=16'd0;
        extra_nonzero<=1'b0; sequence_known<=1'b0; last_sequence<=8'd0;
        a_known<=1'b0; b_known<=1'b0; a_id<=4'd0; b_id<=4'd0; a_down<=1'b0; b_down<=1'b0;
        a_x<=16'd0; a_y<=16'd0; b_x<=16'd0; b_y<=16'd0;
        ack_request<=1'b0; update_valid<=1'b0; press_mask<=2'd0; release_mask<=2'd0; frame_seq<=8'd0;
        good_count<=16'd0; checksum_error_count<=16'd0; format_error_count<=16'd0;
        sequence_gap_count<=16'd0; timeout_count<=16'd0; uart_error_count<=16'd0;
    end else begin
        ack_request<=1'b0; update_valid<=1'b0; press_mask<=2'd0; release_mask<=2'd0;
        if (state==HEAD || byte_valid) idle_ticks<=32'd0;
        else if (idle_ticks!=TIMEOUT_LIMIT) idle_ticks<=idle_ticks+32'd1;
        if (byte_error) begin
            state<=HEAD; idle_ticks<=32'd0; uart_error_count<=uart_error_count+16'd1;
        end else if (state!=HEAD && idle_ticks==TIMEOUT_LIMIT && !byte_valid) begin
            state<=HEAD; idle_ticks<=32'd0; timeout_count<=timeout_count+16'd1;
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
                    else format_error_count<=format_error_count+16'd1;
                    state<=HEAD;
                end
                LENGTH: begin
                    if (byte_data>=8'd3 && byte_data<=8'd72) begin
                        frame_length<=byte_data[6:0]; body_index<=7'd0; checksum<=8'd0;
                        identifier<=8'd0; report_id<=8'd0; report_count<=8'd0; frame_sequence<=8'd0;
                        c0_status<=8'd0; c1_status<=8'd0; c0_x<=16'd0; c0_y<=16'd0; c1_x<=16'd0; c1_y<=16'd0;
                        extra_nonzero<=1'b0; state<=BODY;
                    end else begin
                        format_error_count<=format_error_count+16'd1;
                        state<=byte_data==8'h57 ? MAGIC : HEAD;
                    end
                end
                BODY: begin
                    if (body_index==frame_length-7'd1) begin
                        state<=HEAD;
                        if (byte_data!=checksum) checksum_error_count<=checksum_error_count+16'd1;
                        else begin
                            if (sequence_known && frame_sequence!=last_sequence+8'd1)
                                sequence_gap_count<=sequence_gap_count+16'd1;
                            last_sequence<=frame_sequence; sequence_known<=1'b1;
                            if (!report_ok) format_error_count<=format_error_count+16'd1;
                            else begin
                                a_id<=next_a_id; a_down<=next_a_down; a_x<=next_a_x; a_y<=next_a_y; a_known<=next_a_known;
                                b_id<=next_b_id; b_down<=next_b_down; b_x<=next_b_x; b_y<=next_b_y; b_known<=next_b_known;
                                press_mask<={next_b_down && (!b_down || next_b_id!=b_id), next_a_down && (!a_down || next_a_id!=a_id)};
                                release_mask<={b_down && (!next_b_down || next_b_id!=b_id), a_down && (!next_a_down || next_a_id!=a_id)};
                                frame_seq<=frame_sequence; update_valid<=1'b1; good_count<=good_count+16'd1;
                            end
                        end
                    end else begin
                        body_index<=body_index+7'd1;
                        if (body_index!=7'd0) checksum<=checksum+byte_data;
                        if (body_index==frame_length-7'd2) frame_sequence<=byte_data;
                        else case (body_index)
                            7'd0: identifier<=byte_data;
                            7'd1: report_id<=byte_data;
                            7'd2: c0_status<=byte_data;
                            7'd3: c0_x[7:0]<=byte_data;
                            7'd4: c0_x[15:8]<=byte_data;
                            7'd5: c0_y[7:0]<=byte_data;
                            7'd6: c0_y[15:8]<=byte_data;
                            7'd7: c1_status<=byte_data;
                            7'd8: c1_x[7:0]<=byte_data;
                            7'd9: c1_x[15:8]<=byte_data;
                            7'd10: c1_y[7:0]<=byte_data;
                            7'd11: c1_y[15:8]<=byte_data;
                            7'd54: report_count<=byte_data;
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
