// 115200-8N1 UART command receiver, clocked from the 50 MHz board clock.
// Every correctly received byte is returned through echo_valid/echo_data, so a
// terminal can distinguish an FPGA response from its own local echo.
// Commands: B/b=brightness, V/v=volume, N=next picture, A=auto-play toggle,
// and 1..4=auto-play interval in seconds.  Each received byte is echoed.
module uart_command_control #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200
)(
    input wire clk, input wire rst, input wire uart_rxd,
    output reg [2:0] brightness_level, output reg [2:0] volume_level,
    // playback_command is held until the next command.  Its toggle is the
    // event token safely transferred to the SD/playback clock domain.
    output reg [2:0] playback_command,
    output reg playback_command_toggle,
    output reg echo_valid, output reg [7:0] echo_data
);
localparam [2:0] PLAY_CMD_NONE        = 3'd0;
localparam [2:0] PLAY_CMD_NEXT        = 3'd1;
localparam [2:0] PLAY_CMD_AUTO_TOGGLE = 3'd2;
localparam [2:0] PLAY_CMD_PERIOD_1S   = 3'd3;
localparam [2:0] PLAY_CMD_PERIOD_2S   = 3'd4;
localparam [2:0] PLAY_CMD_PERIOD_3S   = 3'd5;
localparam [2:0] PLAY_CMD_PERIOD_4S   = 3'd6;
localparam integer BIT_TICKS = CLK_HZ / BAUD;
localparam integer HALF_BIT_TICKS = BIT_TICKS / 2;
localparam [1:0] RX_IDLE  = 2'd0, RX_START = 2'd1,
                 RX_DATA  = 2'd2, RX_STOP  = 2'd3;
// Keep this as ordinary RTL synchronizer flops.  TD 6.2 does not honour the
// Xilinx-style ASYNC_REG attribute here and can leave the attributed flop
// reported as having an undriven clock.
reg rx_meta;
reg rx_sync;
reg rx_prev;
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
        rx_meta<=uart_rxd; rx_sync<=rx_meta; rx_prev<=rx_sync;
        byte_valid<=1'b0;
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
        brightness_level<=3'd4; volume_level<=3'd4;
        playback_command<=PLAY_CMD_NONE; playback_command_toggle<=1'b0;
        echo_valid<=1'b0; echo_data<=8'd0;
    end else begin
        echo_valid<=1'b0;
        if (byte_valid) begin
            echo_valid<=1'b1;
            echo_data<=byte_data;
            case (byte_data)
                "B": if (brightness_level < 3'd7) brightness_level <= brightness_level + 3'd1;
                "b": if (brightness_level > 3'd0) brightness_level <= brightness_level - 3'd1;
                "V": if (volume_level < 3'd7) volume_level <= volume_level + 3'd1;
                "v": if (volume_level > 3'd0) volume_level <= volume_level - 3'd1;
                "N", "n": begin
                    playback_command <= PLAY_CMD_NEXT;
                    playback_command_toggle <= ~playback_command_toggle;
                end
                "A", "a": begin
                    playback_command <= PLAY_CMD_AUTO_TOGGLE;
                    playback_command_toggle <= ~playback_command_toggle;
                end
                "1": begin
                    playback_command <= PLAY_CMD_PERIOD_1S;
                    playback_command_toggle <= ~playback_command_toggle;
                end
                "2": begin
                    playback_command <= PLAY_CMD_PERIOD_2S;
                    playback_command_toggle <= ~playback_command_toggle;
                end
                "3": begin
                    playback_command <= PLAY_CMD_PERIOD_3S;
                    playback_command_toggle <= ~playback_command_toggle;
                end
                "4": begin
                    playback_command <= PLAY_CMD_PERIOD_4S;
                    playback_command_toggle <= ~playback_command_toggle;
                end
                default: ;
            endcase
        end
    end
end
endmodule

// One-byte, 8N1 transmitter.  echo_valid is deliberately a one-cycle pulse;
// command bytes are more than one frame apart in normal terminal use.
module uart_echo_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200
)(
    input wire clk,
    input wire rst,
    input wire data_valid,
    input wire [7:0] data,
    output reg uart_txd
);
localparam integer BIT_TICKS = CLK_HZ / BAUD;
reg [8:0] tick_count;
reg [3:0] bit_index;
reg [9:0] shift_frame;
reg busy;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        uart_txd  <= 1'b1;
        tick_count <= 9'd0;
        bit_index  <= 4'd0;
        shift_frame <= 10'h3ff;
        busy <= 1'b0;
    end else if (!busy) begin
        uart_txd <= 1'b1;
        if (data_valid) begin
            // {stop, data[7:0], start}; LSB is sent first.
            shift_frame <= {1'b1, data, 1'b0};
            uart_txd <= 1'b0;
            tick_count <= BIT_TICKS - 1;
            bit_index <= 4'd0;
            busy <= 1'b1;
        end
    end else if (tick_count != 0) begin
        tick_count <= tick_count - 9'd1;
    end else begin
        tick_count <= BIT_TICKS - 1;
        if (bit_index == 4'd9) begin
            uart_txd <= 1'b1;
            busy <= 1'b0;
        end else begin
            bit_index <= bit_index + 4'd1;
            uart_txd <= shift_frame[bit_index + 4'd1];
        end
    end
end
endmodule
