// 串口监视与原快捷键回显共用 CH340 TX。逐行发送，行内不插入回显字符。
// 普通坐标 20 Hz 取样；按下/松开优先入四项事件队列。拥堵不反压解析器。
// 队列溢出仅影响监视文本，分别计数；统计每秒输出一次，所有数值为十六进制。
// 数值预装入移位流，每发一个数字才移四位，避免宽数据的逐字符多路选择器。
module touch_serial_monitor #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200,
    parameter integer SNAPSHOT_MS = 50
)(
    input wire clk, input wire rst,
    input wire update_valid,
    input wire [3:0] a_id, input wire a_down, input wire [15:0] a_x, input wire [15:0] a_y,
    input wire [3:0] b_id, input wire b_down, input wire [15:0] b_x, input wire [15:0] b_y,
    input wire [1:0] press_mask, input wire [1:0] release_mask, input wire [7:0] frame_seq,
    input wire [15:0] good_count, input wire [15:0] checksum_error_count,
    input wire [15:0] format_error_count, input wire [15:0] sequence_gap_count,
    input wire [15:0] timeout_count, input wire [15:0] uart_error_count, input wire [15:0] ack_count,
    input wire echo_valid, input wire [7:0] echo_data,
    output wire uart_txd, output reg [15:0] monitor_drop_count, output reg [15:0] echo_drop_count
);
localparam [15:0] MS_LIMIT = CLK_HZ / 1000 - 1;
localparam [15:0] SNAPSHOT_LIMIT = SNAPSHOT_MS - 1;
reg [15:0] ms_ticks, snapshot_ticks;
reg [9:0] stats_ticks;
reg snapshot_due, stats_due;
reg [85:0] event_mem [0:3];
reg [1:0] event_wr, event_rd;
reg [2:0] event_count;
reg [7:0] echo_mem [0:15];
reg [3:0] echo_wr, echo_rd;
reg [4:0] echo_count;
reg line_busy, stats_line;
reg [6:0] line_index;
reg [143:0] hex_stream;
reg [7:0] line_token;
wire [7:0] line_char = line_token==8'hff ? hex_char(hex_stream[143:140]) : line_token;
wire [85:0] queued_event = event_mem[event_rd];
wire tx_ready;
wire ms_tick = ms_ticks==MS_LIMIT;
wire push_event = update_valid && (snapshot_due || press_mask!=2'd0 || release_mask!=2'd0);
wire pop_event = !line_busy && echo_count==5'd0 && !stats_due && event_count!=3'd0;
wire accept_event = push_event && (event_count<3'd4 || pop_event);
wire pop_echo = !line_busy && echo_count!=5'd0 && tx_ready;
wire accept_echo = echo_valid && (echo_count<5'd16 || pop_echo);
wire tx_valid = line_busy || echo_count!=5'd0;
wire [7:0] tx_data = line_busy ? line_char : echo_mem[echo_rd];

function [7:0] hex_char;
    input [3:0] nibble;
    begin
        if (nibble<4'd10) hex_char=8'h30+{4'd0,nibble};
        else hex_char=8'h41+{4'd0,nibble}-8'd10;
    end
endfunction
always @* begin
    line_token=8'h20;
    if (!stats_line) begin
        case (line_index)
            7'd0: line_token=8'h54;
            7'd1: line_token=8'h20;
            7'd2: line_token=8'hff;
            7'd3: line_token=8'hff;
            7'd4: line_token=8'h20;
            7'd5: line_token=8'h41;
            7'd6: line_token=8'h3a;
            7'd7: line_token=8'hff;
            7'd8: line_token=8'h2c;
            7'd9: line_token=8'hff;
            7'd10: line_token=8'h2c;
            7'd11: line_token=8'hff;
            7'd12: line_token=8'hff;
            7'd13: line_token=8'hff;
            7'd14: line_token=8'hff;
            7'd15: line_token=8'h2c;
            7'd16: line_token=8'hff;
            7'd17: line_token=8'hff;
            7'd18: line_token=8'hff;
            7'd19: line_token=8'hff;
            7'd20: line_token=8'h20;
            7'd21: line_token=8'h42;
            7'd22: line_token=8'h3a;
            7'd23: line_token=8'hff;
            7'd24: line_token=8'h2c;
            7'd25: line_token=8'hff;
            7'd26: line_token=8'h2c;
            7'd27: line_token=8'hff;
            7'd28: line_token=8'hff;
            7'd29: line_token=8'hff;
            7'd30: line_token=8'hff;
            7'd31: line_token=8'h2c;
            7'd32: line_token=8'hff;
            7'd33: line_token=8'hff;
            7'd34: line_token=8'hff;
            7'd35: line_token=8'hff;
            7'd36: line_token=8'h20;
            7'd37: line_token=8'h50;
            7'd38: line_token=8'h3a;
            7'd39: line_token=8'hff;
            7'd40: line_token=8'h20;
            7'd41: line_token=8'h52;
            7'd42: line_token=8'h3a;
            7'd43: line_token=8'hff;
            7'd44: line_token=8'h0d;
            7'd45: line_token=8'h0a;
            default: line_token=8'h20;
        endcase
    end else begin
        case (line_index)
            7'd0: line_token=8'h53;
            7'd1: line_token=8'h20;
            7'd2: line_token=8'h6f;
            7'd3: line_token=8'h6b;
            7'd4: line_token=8'h3d;
            7'd5: line_token=8'hff;
            7'd6: line_token=8'hff;
            7'd7: line_token=8'hff;
            7'd8: line_token=8'hff;
            7'd9: line_token=8'h20;
            7'd10: line_token=8'h73;
            7'd11: line_token=8'h75;
            7'd12: line_token=8'h6d;
            7'd13: line_token=8'h3d;
            7'd14: line_token=8'hff;
            7'd15: line_token=8'hff;
            7'd16: line_token=8'hff;
            7'd17: line_token=8'hff;
            7'd18: line_token=8'h20;
            7'd19: line_token=8'h66;
            7'd20: line_token=8'h6d;
            7'd21: line_token=8'h74;
            7'd22: line_token=8'h3d;
            7'd23: line_token=8'hff;
            7'd24: line_token=8'hff;
            7'd25: line_token=8'hff;
            7'd26: line_token=8'hff;
            7'd27: line_token=8'h20;
            7'd28: line_token=8'h67;
            7'd29: line_token=8'h61;
            7'd30: line_token=8'h70;
            7'd31: line_token=8'h3d;
            7'd32: line_token=8'hff;
            7'd33: line_token=8'hff;
            7'd34: line_token=8'hff;
            7'd35: line_token=8'hff;
            7'd36: line_token=8'h20;
            7'd37: line_token=8'h72;
            7'd38: line_token=8'h78;
            7'd39: line_token=8'h3d;
            7'd40: line_token=8'hff;
            7'd41: line_token=8'hff;
            7'd42: line_token=8'hff;
            7'd43: line_token=8'hff;
            7'd44: line_token=8'h20;
            7'd45: line_token=8'h74;
            7'd46: line_token=8'h6f;
            7'd47: line_token=8'h3d;
            7'd48: line_token=8'hff;
            7'd49: line_token=8'hff;
            7'd50: line_token=8'hff;
            7'd51: line_token=8'hff;
            7'd52: line_token=8'h20;
            7'd53: line_token=8'h61;
            7'd54: line_token=8'h63;
            7'd55: line_token=8'h6b;
            7'd56: line_token=8'h3d;
            7'd57: line_token=8'hff;
            7'd58: line_token=8'hff;
            7'd59: line_token=8'hff;
            7'd60: line_token=8'hff;
            7'd61: line_token=8'h20;
            7'd62: line_token=8'h64;
            7'd63: line_token=8'h72;
            7'd64: line_token=8'h6f;
            7'd65: line_token=8'h70;
            7'd66: line_token=8'h3d;
            7'd67: line_token=8'hff;
            7'd68: line_token=8'hff;
            7'd69: line_token=8'hff;
            7'd70: line_token=8'hff;
            7'd71: line_token=8'h20;
            7'd72: line_token=8'h65;
            7'd73: line_token=8'h63;
            7'd74: line_token=8'h68;
            7'd75: line_token=8'h6f;
            7'd76: line_token=8'h3d;
            7'd77: line_token=8'hff;
            7'd78: line_token=8'hff;
            7'd79: line_token=8'hff;
            7'd80: line_token=8'hff;
            7'd81: line_token=8'h0d;
            7'd82: line_token=8'h0a;
            default: line_token=8'h20;
        endcase
    end
end
uart_byte_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx(
    .clk(clk),.rst(rst),.valid(tx_valid),.data(tx_data),.ready(tx_ready),.txd(uart_txd));

always @(posedge clk or posedge rst) begin
    if (rst) begin
        ms_ticks<=16'd0; snapshot_ticks<=16'd0; stats_ticks<=10'd0;
        snapshot_due<=1'b1; stats_due<=1'b0;
        event_wr<=2'd0; event_rd<=2'd0; event_count<=3'd0;
        echo_wr<=4'd0; echo_rd<=4'd0; echo_count<=5'd0;
        line_busy<=1'b0; stats_line<=1'b0; line_index<=7'd0;
        hex_stream<=144'd0;
        monitor_drop_count<=16'd0; echo_drop_count<=16'd0;
    end else begin
        if (ms_tick) begin
            ms_ticks<=16'd0;
            if (snapshot_ticks==SNAPSHOT_LIMIT) begin snapshot_ticks<=16'd0; snapshot_due<=1'b1; end
            else snapshot_ticks<=snapshot_ticks+16'd1;
            if (stats_ticks==10'd999) begin stats_ticks<=10'd0; stats_due<=1'b1; end
            else stats_ticks<=stats_ticks+10'd1;
        end else ms_ticks<=ms_ticks+16'd1;

        if (push_event) begin
            snapshot_due<=ms_tick && snapshot_ticks==SNAPSHOT_LIMIT;
            if (!accept_event) monitor_drop_count<=monitor_drop_count+16'd1;
        end
        if (accept_event) begin
            event_mem[event_wr]<={frame_seq,a_id,a_down,a_x,a_y,b_id,b_down,b_x,b_y,press_mask,release_mask};
            event_wr<=event_wr+2'd1;
        end
        if (pop_event) event_rd<=event_rd+2'd1;
        case ({accept_event,pop_event})
            2'b10: event_count<=event_count+3'd1;
            2'b01: event_count<=event_count-3'd1;
            default: ;
        endcase

        if (echo_valid && !accept_echo) echo_drop_count<=echo_drop_count+16'd1;
        if (accept_echo) begin echo_mem[echo_wr]<=echo_data; echo_wr<=echo_wr+4'd1; end
        if (pop_echo) echo_rd<=echo_rd+4'd1;
        case ({accept_echo,pop_echo})
            2'b10: echo_count<=echo_count+5'd1;
            2'b01: echo_count<=echo_count-5'd1;
            default: ;
        endcase

        if (!line_busy && echo_count==5'd0) begin
            if (stats_due) begin
                line_busy<=1'b1; stats_line<=1'b1; line_index<=7'd0;
                hex_stream<={good_count,checksum_error_count,format_error_count,sequence_gap_count,
                             uart_error_count,timeout_count,ack_count,monitor_drop_count,echo_drop_count};
                stats_due<=ms_tick && stats_ticks==10'd999;
            end else if (pop_event) begin
                line_busy<=1'b1; stats_line<=1'b0; line_index<=7'd0;
                hex_stream<={queued_event[85:78],queued_event[77:74],3'd0,queued_event[73],
                             queued_event[72:57],queued_event[56:41],queued_event[40:37],3'd0,queued_event[36],
                             queued_event[35:20],queued_event[19:4],2'd0,queued_event[3:2],2'd0,queued_event[1:0],48'd0};
            end
        end else if (line_busy && tx_ready) begin
            if (line_token==8'hff) hex_stream<={hex_stream[139:0],4'd0};
            if ((!stats_line && line_index==7'd45) ||
                (stats_line && line_index==7'd82)) line_busy<=1'b0;
            else line_index<=line_index+7'd1;
        end
    end
end
endmodule
