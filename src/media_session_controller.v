module media_session_controller #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer AUTO_PERIOD_SECONDS = 3
)(
    input wire clk, input wire rst, input wire key_next, input wire key_auto,
    // uart_command_async and its toggle originate in the 50 MHz UART domain.
    // The command value is held stable whenever its toggle changes.
    input wire [2:0] uart_command_async, input wire uart_command_toggle_async,
    input wire scan_done, input wire [2:0] media_count, input wire loader_ready,
    input wire frame_commit, output reg load_start, output reg [1:0] load_media_index,
    output reg [1:0] write_slot, output reg [1:0] display_slot,
    output reg display_valid, output reg auto_play_enabled, output reg load_inflight
);
reg [31:0] auto_count;
reg [31:0] auto_period_cycles;
// Manual presses are kept while a BMP is being fetched/written.  A single
// flag used to overwrite a later press when the previous request was being
// started, which made a valid press during a picture switch look lost.
reg [2:0] manual_next_pending;
reg auto_next_pending;
reg [2:0] uart_command_meta;
reg [2:0] uart_command_sync;
reg uart_toggle_meta;
reg uart_toggle_sync;
reg uart_toggle_seen;
localparam [2:0] UART_CMD_NEXT        = 3'd1;
localparam [2:0] UART_CMD_AUTO_TOGGLE = 3'd2;
localparam [2:0] UART_CMD_PERIOD_1S   = 3'd3;
localparam [2:0] UART_CMD_PERIOD_2S   = 3'd4;
localparam [2:0] UART_CMD_PERIOD_3S   = 3'd5;
localparam [2:0] UART_CMD_PERIOD_4S   = 3'd6;
wire key_next_press;
wire key_auto_press;
wire uart_command_event = (uart_toggle_sync != uart_toggle_seen);
wire [31:0] auto_limit = auto_period_cycles;
wire auto_due = (auto_count >= auto_limit - 1);
wire start_manual_next = !load_inflight && loader_ready && display_valid &&
                         (manual_next_pending != 3'd0);

function [1:0] next_media;
    input [1:0] current; input [2:0] count;
    begin
        if (count < 3'd2) next_media = 2'd0;
        else if (current + 2'd1 >= count) next_media = 2'd0;
        else next_media = current + 2'd1;
    end
endfunction
function [1:0] next_slot;
    input [1:0] current;
    begin
        if (current == 2'd2) next_slot = 2'd0;
        else next_slot = current + 2'd1;
    end
endfunction

media_key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(20)) u_key_next (
    .clk(clk), .rst(rst), .button_n(key_next), .press_pulse(key_next_press)
);
media_key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(20)) u_key_auto (
    .clk(clk), .rst(rst), .button_n(key_auto), .press_pulse(key_auto_press)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        load_start<=1'b0; load_media_index<=2'd0; write_slot<=2'd0; display_slot<=2'd0;
        display_valid<=1'b0; auto_play_enabled<=1'b0; load_inflight<=1'b0;
        auto_count<=32'd0; auto_period_cycles<=CLK_FREQ_HZ * AUTO_PERIOD_SECONDS;
        manual_next_pending<=3'd0; auto_next_pending<=1'b0;
        uart_command_meta<=3'd0; uart_command_sync<=3'd0;
        uart_toggle_meta<=1'b0; uart_toggle_sync<=1'b0; uart_toggle_seen<=1'b0;
    end else begin
        // Two flip-flops for the held command bus and event toggle.  The UART
        // source changes the bus before toggling the event and keeps it until
        // the next command, giving the destination two full clocks to settle.
        uart_command_meta <= uart_command_async;
        uart_command_sync <= uart_command_meta;
        uart_toggle_meta <= uart_command_toggle_async;
        uart_toggle_sync <= uart_toggle_meta;
        load_start<=1'b0;
        if (!scan_done || media_count==3'd0) begin
            display_valid<=1'b0; auto_play_enabled<=1'b0; load_inflight<=1'b0;
            auto_count<=32'd0; manual_next_pending<=3'd0; auto_next_pending<=1'b0;
            uart_toggle_seen<=uart_toggle_sync;
        end else begin
            // A manual press is valid as soon as scanning is complete.  This
            // also captures a press during the first-image load instead of
            // silently discarding it because display_valid is still low.
            if ((key_next_press || (uart_command_event && uart_command_sync == UART_CMD_NEXT)) && media_count != 3'd0) begin
                if (start_manual_next) begin
                    // One request is consumed and one arrives in this cycle.
                    manual_next_pending <= manual_next_pending;
                end else if (manual_next_pending < 3'd7) begin
                    manual_next_pending <= manual_next_pending + 3'd1;
                end
            end else if (start_manual_next) begin
                manual_next_pending <= manual_next_pending - 3'd1;
            end

            if (uart_command_event) begin
                uart_toggle_seen <= uart_toggle_sync;
                case (uart_command_sync)
                    UART_CMD_AUTO_TOGGLE: if (media_count > 3'd1) begin
                        auto_play_enabled <= ~auto_play_enabled;
                        auto_count <= 32'd0;
                        auto_next_pending <= 1'b0;
                    end
                    UART_CMD_PERIOD_1S: begin auto_period_cycles <= CLK_FREQ_HZ * 1; auto_count <= 32'd0; end
                    UART_CMD_PERIOD_2S: begin auto_period_cycles <= CLK_FREQ_HZ * 2; auto_count <= 32'd0; end
                    UART_CMD_PERIOD_3S: begin auto_period_cycles <= CLK_FREQ_HZ * 3; auto_count <= 32'd0; end
                    UART_CMD_PERIOD_4S: begin auto_period_cycles <= CLK_FREQ_HZ * 4; auto_count <= 32'd0; end
                    default: ;
                endcase
            end

            if (key_auto_press && media_count>3'd1) begin
                auto_play_enabled<=~auto_play_enabled;
                auto_count<=32'd0;
                auto_next_pending<=1'b0;
            end else if ((uart_command_event && uart_command_sync == UART_CMD_AUTO_TOGGLE) ||
                         (uart_command_event && (uart_command_sync >= UART_CMD_PERIOD_1S))) begin
                // The command handler above has already reset auto_count.
            end else if (auto_play_enabled && display_valid && !load_inflight && media_count>3'd1) begin
                if (auto_due) begin auto_count<=32'd0; auto_next_pending<=1'b1; end
                else auto_count<=auto_count+32'd1;
            end else auto_count<=32'd0;
            if (load_inflight && frame_commit) begin display_slot<=write_slot; display_valid<=1'b1; load_inflight<=1'b0; end
            if (!load_inflight && loader_ready) begin
                if (!display_valid) begin load_media_index<=2'd0; write_slot<=2'd0; load_start<=1'b1; load_inflight<=1'b1; end
                else if (manual_next_pending != 3'd0) begin
                    load_media_index<=next_media(load_media_index,media_count);
                    write_slot<=next_slot(display_slot); load_start<=1'b1; load_inflight<=1'b1;
                end else if (auto_next_pending) begin
                    load_media_index<=next_media(load_media_index,media_count);
                    write_slot<=next_slot(display_slot); load_start<=1'b1; load_inflight<=1'b1; auto_next_pending<=1'b0;
                end
            end
        end
    end
end
endmodule

// Restored pre-UART playback-domain button filter: active-low press, 20 ms
// debounce.  This is deliberately the same counter/state behavior used by
// the previously verified player path.
module media_key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input wire clk,
    input wire rst,
    input wire button_n,
    output reg press_pulse
);
localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0   <= 1'b1;
        button_sync1   <= 1'b1;
        button_stable  <= 1'b1;
        cnt            <= 32'd0;
        press_pulse    <= 1'b0;
    end else begin
        button_sync0 <= button_n;
        button_sync1 <= button_sync0;
        press_pulse <= 1'b0;
        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end
endmodule
