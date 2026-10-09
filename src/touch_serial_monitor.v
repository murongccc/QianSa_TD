// 串口监视与原快捷键回显共用 CH340 TX。逐行发送，行内不插入回显字符。
// 普通坐标20 Hz取样；队列五项含正在发送一项，与原四项等待队列容量一致。
// 队列溢出仅影响监视文本，分别计数；统计每秒输出一次，所有数值为十六进制。
// 数值逐字段装入16位移位器，避免整行宽寄存器及宽数据逐字符选择。
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
function integer counter_width;
    input integer value;
    integer remaining;
    begin
        remaining=value-1;counter_width=0;
        while(remaining>0)begin counter_width=counter_width+1;remaining=remaining>>1;end
        if(counter_width==0)counter_width=1;
    end
endfunction
localparam integer SNAPSHOT_BITS=counter_width(SNAPSHOT_MS);
localparam [SNAPSHOT_BITS-1:0] SNAPSHOT_LIMIT = SNAPSHOT_MS - 1;
reg [15:0] ms_ticks;
reg [SNAPSHOT_BITS-1:0] snapshot_ticks;
reg [9:0] stats_ticks;
reg snapshot_due, stats_due;
reg [2:0] event_wr, event_rd;
reg [2:0] event_count;
reg event_read_ready;
reg [7:0] echo_mem [0:15];
reg [3:0] echo_wr, echo_rd;
reg [4:0] echo_count;
reg line_busy, stats_line;
reg [2:0] stats_state;
reg [3:0] stats_field;
reg [1:0] stats_digit;
reg [31:0] stats_name;
localparam [2:0] S_HEAD=3'd0,S_HEAD_SPACE=3'd1,S_NAME=3'd2,S_EQUAL=3'd3,
                 S_DIGIT=3'd4,S_SPACE=3'd5,S_CR=3'd6,S_LF=3'd7;
reg [6:0] line_index;
reg [15:0] digit_word;
reg field_load;
reg [15:0] field_value;
reg [7:0] line_token;
wire [7:0] line_char = line_token==8'hff ? hex_char(digit_word[15:12]) : line_token;
wire [85:0] queued_event;
wire tx_ready;
wire ms_tick = ms_ticks==MS_LIMIT;
wire push_event = update_valid && (snapshot_due || press_mask!=2'd0 || release_mask!=2'd0);
wire start_event = !line_busy && echo_count==5'd0 && !stats_due && event_count!=3'd0 && event_read_ready;
wire pop_event = line_busy && !stats_line && line_index==7'd45 && tx_ready;
wire accept_event = push_event && (event_count<3'd5 || pop_event);
wire pop_echo = !line_busy && echo_count!=5'd0 && tx_ready;
wire accept_echo = echo_valid && (echo_count<5'd16 || pop_echo);
wire tx_valid = line_busy || echo_count!=5'd0;
wire [7:0] tx_data = line_busy ? line_char : echo_mem[echo_rd];

// 使用项目同款 BRAM9K 原语，释放宽队列占用的 MSlice；不生成新 IP。
// 同地址写入时暂停读，避免首次入队/满队列换出时产生跨端口读写碰撞。
EG_LOGIC_BRAM #(.IMPLEMENT("9K"),.DATA_WIDTH_A(86),.DATA_WIDTH_B(86),
    .ADDR_WIDTH_A(3),.ADDR_WIDTH_B(3),.DATA_DEPTH_A(8),.DATA_DEPTH_B(8),
    .MODE("PDPW"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),
    .WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) u_event_ram(
    .dia({frame_seq,a_id,a_down,a_x,a_y,b_id,b_down,b_x,b_y,press_mask,release_mask}),.dib(86'd0),
    .addra(event_wr),.addrb(event_rd),.cea(accept_event),.ceb(!(accept_event && event_wr==event_rd)),
    .ocea(1'b0),.oceb(1'b1),.clka(clk),.clkb(clk),.wea(1'b1),.web(1'b0),.bea(1'b0),.beb(1'b0),
    .rsta(1'b0),.rstb(1'b0),.doa(),.dob(queued_event));

function [7:0] hex_char;
    input [3:0] nibble;
    begin
        if (nibble<4'd10) hex_char=8'h30+{4'd0,nibble};
        else hex_char=8'h41+{4'd0,nibble}-8'd10;
    end
endfunction
function [31:0] counter_name;
    input [3:0] index;
    begin
        case(index)
            4'd0:counter_name=32'h6f6b0000;
            4'd1:counter_name=32'h73756d00;
            4'd2:counter_name=32'h666d7400;
            4'd3:counter_name=32'h67617000;
            4'd4:counter_name=32'h72780000;
            4'd5:counter_name=32'h746f0000;
            4'd6:counter_name=32'h61636b00;
            4'd7:counter_name=32'h64726f70;
            default:counter_name=32'h6563686f;
        endcase
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
        case(stats_state)
            S_HEAD:line_token=8'h53;
            S_HEAD_SPACE,S_SPACE:line_token=8'h20;
            S_NAME:line_token=stats_name[31:24];
            S_EQUAL:line_token=8'h3d;
            S_DIGIT:line_token=8'hff;
            S_CR:line_token=8'h0d;
            default:line_token=8'h0a;
        endcase
    end
end
// 下一个字符开始一个数字字段时锁存整字，数字期间只移四位。
// T包在发送完成前占据队列，全部字段来自同一快照；S各计数器分别原子取样。
always @* begin
    field_load=1'b0;field_value=16'd0;
    if(!stats_line)begin
        case(line_index)
            7'd1: begin field_load=1'b1;field_value={queued_event[85:78],8'd0};end
            7'd6: begin field_load=1'b1;field_value={queued_event[77:74],12'd0};end
            7'd8: begin field_load=1'b1;field_value={3'd0,queued_event[73],12'd0};end
            7'd10: begin field_load=1'b1;field_value=queued_event[72:57];end
            7'd15: begin field_load=1'b1;field_value=queued_event[56:41];end
            7'd22: begin field_load=1'b1;field_value={queued_event[40:37],12'd0};end
            7'd24: begin field_load=1'b1;field_value={3'd0,queued_event[36],12'd0};end
            7'd26: begin field_load=1'b1;field_value=queued_event[35:20];end
            7'd31: begin field_load=1'b1;field_value=queued_event[19:4];end
            7'd38: begin field_load=1'b1;field_value={2'd0,queued_event[3:2],12'd0};end
            7'd42: begin field_load=1'b1;field_value={2'd0,queued_event[1:0],12'd0};end
            default: ;
        endcase
    end else if(stats_state==S_EQUAL)begin
        field_load=1'b1;
        case(stats_field)
            4'd0:field_value=good_count;
            4'd1:field_value=checksum_error_count;
            4'd2:field_value=format_error_count;
            4'd3:field_value=sequence_gap_count;
            4'd4:field_value=uart_error_count;
            4'd5:field_value=timeout_count;
            4'd6:field_value=ack_count;
            4'd7:field_value=monitor_drop_count;
            default:field_value=echo_drop_count;
        endcase
    end
end
uart_byte_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx(
    .clk(clk),.rst(rst),.valid(tx_valid),.data(tx_data),.ready(tx_ready),.txd(uart_txd));

always @(posedge clk or posedge rst) begin
    if (rst) begin
        ms_ticks<=16'd0; snapshot_ticks<={SNAPSHOT_BITS{1'b0}}; stats_ticks<=10'd0;
        snapshot_due<=1'b1; stats_due<=1'b0;
        event_wr<=3'd0; event_rd<=3'd0; event_count<=3'd0;
        event_read_ready<=1'b0;
        echo_wr<=4'd0; echo_rd<=4'd0; echo_count<=5'd0;
        line_busy<=1'b0;stats_line<=1'b0;line_index<=7'd0;
        stats_state<=S_HEAD;stats_field<=4'd0;stats_digit<=2'd0;stats_name<=32'd0;
        digit_word<=16'd0;
        monitor_drop_count<=16'd0; echo_drop_count<=16'd0;
    end else begin
        if (ms_tick) begin
            ms_ticks<=16'd0;
            if (snapshot_ticks==SNAPSHOT_LIMIT) begin snapshot_ticks<={SNAPSHOT_BITS{1'b0}}; snapshot_due<=1'b1; end
            else snapshot_ticks<=snapshot_ticks+1'b1;
            if (stats_ticks==10'd999) begin stats_ticks<=10'd0; stats_due<=1'b1; end
            else stats_ticks<=stats_ticks+10'd1;
        end else ms_ticks<=ms_ticks+16'd1;

        if (push_event) begin
            snapshot_due<=ms_tick && snapshot_ticks==SNAPSHOT_LIMIT;
            if (!accept_event) monitor_drop_count<=monitor_drop_count+16'd1;
        end
        if (accept_event) begin
            event_wr<=event_wr==3'd4 ? 3'd0 : event_wr+3'd1;
        end
        if (pop_event) event_rd<=event_rd==3'd4 ? 3'd0 : event_rd+3'd1;
        if(pop_event || (accept_event && event_count==3'd0))event_read_ready<=1'b0;
        else if(event_count!=3'd0)event_read_ready<=1'b1;
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
                line_busy<=1'b1;stats_line<=1'b1;line_index<=7'd0;
                stats_state<=S_HEAD;stats_field<=4'd0;stats_name<=counter_name(4'd0);
                stats_due<=ms_tick && stats_ticks==10'd999;
            end else if (start_event) begin
                line_busy<=1'b1; stats_line<=1'b0; line_index<=7'd0;
            end
        end else if (line_busy && tx_ready) begin
            if(field_load)digit_word<=field_value;
            else if(line_token==8'hff)digit_word<={digit_word[11:0],4'd0};
            if(!stats_line)begin
                if(line_index==7'd45)line_busy<=1'b0;
                else line_index<=line_index+7'd1;
            end else case(stats_state)
                S_HEAD:stats_state<=S_HEAD_SPACE;
                S_HEAD_SPACE:stats_state<=S_NAME;
                S_NAME:begin
                    stats_name<={stats_name[23:0],8'd0};
                    if(stats_name[23:16]==8'd0)stats_state<=S_EQUAL;
                end
                S_EQUAL:begin stats_digit<=2'd0;stats_state<=S_DIGIT;end
                S_DIGIT:begin
                    if(stats_digit==2'd3)stats_state<=stats_field==4'd8 ? S_CR : S_SPACE;
                    else stats_digit<=stats_digit+2'd1;
                end
                S_SPACE:begin
                    stats_field<=stats_field+4'd1;stats_name<=counter_name(stats_field+4'd1);stats_state<=S_NAME;
                end
                S_CR:stats_state<=S_LF;
                default:line_busy<=1'b0;
            endcase
        end
    end
end
endmodule
