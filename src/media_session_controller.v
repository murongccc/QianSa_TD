module media_session_controller #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer AUTO_PERIOD_SECONDS = 3
)(
    input wire clk, input wire rst, input wire key_next, input wire key_auto,
    input wire scan_done, input wire [2:0] media_count, input wire loader_ready,
    input wire frame_commit, output reg load_start, output reg [1:0] load_media_index,
    output reg [1:0] write_slot, output reg [1:0] display_slot,
    output reg display_valid, output reg auto_play_enabled, output reg load_inflight
);
reg [31:0] auto_count;
reg next_request;
wire key_next_press;
wire key_auto_press;
wire [31:0] auto_limit = CLK_FREQ_HZ * AUTO_PERIOD_SECONDS;
wire auto_due = (auto_count == auto_limit - 1);

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
        auto_count<=32'd0; next_request<=1'b0;
    end else begin
        load_start<=1'b0;
        if (!scan_done || media_count==3'd0) begin
            display_valid<=1'b0; auto_play_enabled<=1'b0; load_inflight<=1'b0;
            auto_count<=32'd0; next_request<=1'b0;
        end else begin
            if (key_auto_press && media_count>3'd1) begin auto_play_enabled<=~auto_play_enabled; auto_count<=32'd0; end
            if (key_next_press && display_valid) next_request<=1'b1;
            if (auto_play_enabled && display_valid && !load_inflight && media_count>3'd1) begin
                if (auto_due) begin auto_count<=32'd0; next_request<=1'b1; end
                else auto_count<=auto_count+32'd1;
            end else auto_count<=32'd0;
            if (load_inflight && frame_commit) begin display_slot<=write_slot; display_valid<=1'b1; load_inflight<=1'b0; end
            if (!load_inflight && loader_ready) begin
                if (!display_valid) begin load_media_index<=2'd0; write_slot<=2'd0; load_start<=1'b1; load_inflight<=1'b1; end
                else if (next_request) begin
                    load_media_index<=next_media(load_media_index,media_count);
                    write_slot<=next_slot(display_slot); load_start<=1'b1; load_inflight<=1'b1; next_request<=1'b0;
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
