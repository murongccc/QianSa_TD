// 115200-8N1 UART command receiver, clocked from the 50 MHz board clock.
// Commands: N=next, A=auto toggle, 1..4=period seconds, B/b=brightness,
// V/v=volume.  Event toggles are used for safe transfer to other domains.
module uart_command_control #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200
)(
    input wire clk, input wire rst, input wire uart_rxd,
    output reg next_toggle, output reg auto_toggle,
    output reg [2:0] period_seconds, output reg [6:0] brightness,
    output reg [7:0] volume
);
localparam integer BIT_TICKS = CLK_HZ / BAUD;
localparam integer HALF_BIT_TICKS = BIT_TICKS / 2;
localparam [1:0] RX_IDLE  = 2'd0, RX_START = 2'd1,
                 RX_DATA  = 2'd2, RX_STOP  = 2'd3;
reg rx_meta, rx_sync, rx_prev;
reg [1:0] rx_state;
reg [8:0] tick_count;
reg [2:0] bit_count;
reg [7:0] shift_data;
reg byte_valid;
reg [7:0] byte_data;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rx_meta<=1'b1; rx_sync<=1'b1; rx_prev<=1'b1; rx_state<=RX_IDLE;
        tick_count<=9'd0; bit_count<=4'd0; shift_data<=8'd0;
        byte_valid<=1'b0; byte_data<=8'd0;
    end else begin
        rx_meta<=uart_rxd; rx_sync<=rx_meta; rx_prev<=rx_sync; byte_valid<=1'b0;
        case (rx_state)
            RX_IDLE: begin
                if (rx_prev && !rx_sync) begin
                    // Validate the start level at its centre before sampling data.
                    rx_state<=RX_START; tick_count<=HALF_BIT_TICKS-1;
                end
            end
            RX_START: begin
                if (tick_count != 0) tick_count<=tick_count-9'd1;
                else if (!rx_sync) begin
                    rx_state<=RX_DATA; tick_count<=BIT_TICKS-1; bit_count<=3'd0;
                end else rx_state<=RX_IDLE;
            end
            RX_DATA: begin
                if (tick_count != 0) tick_count<=tick_count-9'd1;
                else begin
                    shift_data[bit_count]<=rx_sync;
                    tick_count<=BIT_TICKS-1;
                    if (bit_count==3'd7) rx_state<=RX_STOP;
                    else bit_count<=bit_count+3'd1;
                end
            end
            default: begin // RX_STOP
                if (tick_count != 0) tick_count<=tick_count-9'd1;
                else begin
                    rx_state<=RX_IDLE;
                    if (rx_sync) begin byte_data<=shift_data; byte_valid<=1'b1; end
                end
            end
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_toggle<=1'b0; auto_toggle<=1'b0; period_seconds<=3'd3;
        brightness<=7'd64; volume<=8'd96;
    end else if (byte_valid) begin
        case (byte_data)
            "N", "n": next_toggle <= ~next_toggle;
            "A", "a": auto_toggle <= ~auto_toggle;
            "1": period_seconds <= 3'd1;
            "2": period_seconds <= 3'd2;
            "3": period_seconds <= 3'd3;
            "4": period_seconds <= 3'd4;
            "B": if (brightness < 7'd112) brightness <= brightness + 7'd16;
            "b": if (brightness > 7'd16)  brightness <= brightness - 7'd16;
            "V": if (volume < 8'd224) volume <= volume + 8'd32;
            "v": if (volume > 8'd32)  volume <= volume - 8'd32;
            default: ;
        endcase
    end
end
endmodule
