// 独立 CH9350 串口：接收触摸报告，状态请求自动应答；不接收电脑快捷键。
module ch9350_touch_input #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200,
    parameter integer FRAME_TIMEOUT_MS = 20
)(
    input wire clk, input wire rst, input wire touch_rxd, output wire touch_txd,
    output wire update_valid,
    output wire [3:0] a_id, output wire a_down, output wire [15:0] a_x, output wire [15:0] a_y,
    output wire [3:0] b_id, output wire b_down, output wire [15:0] b_x, output wire [15:0] b_y,
    output wire [3:0] c_id, output wire c_down, output wire [15:0] c_x,c_y, output wire all_down,
    output wire [1:0] press_mask, output wire [1:0] release_mask, output wire [7:0] frame_seq,
    output wire [15:0] good_count, output wire [15:0] checksum_error_count,
    output wire [15:0] format_error_count, output wire [15:0] sequence_gap_count,
    output wire [15:0] timeout_count, output wire [15:0] uart_error_count,
    output reg [15:0] ack_count
);
wire rx_valid, rx_error, ack_request, tx_ready;
wire [7:0] rx_data;
reg ack_pending, ack_active;
reg [3:0] ack_index;
reg [7:0] ack_data;
uart_byte_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_rx(
    .clk(clk),.rst(rst),.rxd(touch_rxd),.data(rx_data),.valid(rx_valid),.error(rx_error));
ch9350_touch_parser #(.CLK_HZ(CLK_HZ),.FRAME_TIMEOUT_MS(FRAME_TIMEOUT_MS)) u_parser(
    .clk(clk),.rst(rst),.byte_valid(rx_valid),.byte_data(rx_data),.byte_error(rx_error),
    .ack_request(ack_request),.update_valid(update_valid),
    .a_id(a_id),.a_down(a_down),.a_x(a_x),.a_y(a_y),.b_id(b_id),.b_down(b_down),.b_x(b_x),.b_y(b_y),
    .c_id(c_id),.c_down(c_down),.c_x(c_x),.c_y(c_y),.all_down(all_down),
    .press_mask(press_mask),.release_mask(release_mask),.frame_seq(frame_seq),
    .good_count(good_count),.checksum_error_count(checksum_error_count),.format_error_count(format_error_count),
    .sequence_gap_count(sequence_gap_count),.timeout_count(timeout_count),.uart_error_count(uart_error_count));
// 把完整的状态 0 应答逐字节握手送出，不由电脑串口与本发送器争用 TX。
always @* begin
    case (ack_index)
        4'd0: ack_data=8'h57;
        4'd1: ack_data=8'hab;
        4'd2: ack_data=8'h12;
        4'd7: ack_data=8'hff;
        4'd8: ack_data=8'h80;
        4'd10: ack_data=8'h20;
        default: ack_data=8'h00;
    endcase
end
uart_byte_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_ack_tx(
    .clk(clk),.rst(rst),.valid(ack_active),.data(ack_data),.ready(tx_ready),.txd(touch_txd));
always @(posedge clk or posedge rst) begin
    if (rst) begin ack_pending<=1'b0; ack_active<=1'b0; ack_index<=4'd0; ack_count<=16'd0; end
    else begin
        if (ack_request) ack_pending<=1'b1;
        if (!ack_active && ack_pending) begin
            ack_pending<=ack_request; ack_active<=1'b1; ack_index<=4'd0;
        end else if (ack_active && tx_ready) begin
            if (ack_index==4'd10) begin ack_active<=1'b0; ack_count<=ack_count+16'd1; end
            else ack_index<=ack_index+4'd1;
        end
    end
end
endmodule
