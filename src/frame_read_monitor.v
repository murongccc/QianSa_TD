`timescale 1ns/1ps

// 视频帧读出诊断：分别记录 FIFO 空读和同槽帧数据变化。
// 所有计数仅在 display_valid 后工作，避免把上电装载阶段计为故障。
module frame_read_monitor #(
    parameter integer FRAME_PIXELS = 307200
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        display_valid_async,
    input  wire [1:0]  display_slot_async,
    input  wire        vs,
    input  wire        fifo_read_req,
    input  wire        fifo_empty,
    input  wire        fifo_valid,
    input  wire [31:0] fifo_data,
    output reg  [15:0] underflow_count,
    output reg         underflow_sticky,
    output reg  [15:0] mismatch_count,
    output reg         mismatch_sticky
);

localparam [18:0] EXPECTED_PIXEL_COUNT = FRAME_PIXELS;

reg        display_valid_meta, display_valid_sync;
reg [1:0]  slot_meta, slot_sync, frame_slot;
reg        vs_d;
reg        frame_monitor_active;
reg [18:0] pixel_count;
reg [31:0] frame_signature;
reg [31:0] baseline_signature [0:2];
reg [2:0]  baseline_valid;

wire frame_start = vs && !vs_d;
wire [31:0] signature_next = {frame_signature[30:0], frame_signature[31]} ^
                             fifo_data ^ {13'd0, pixel_count};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        display_valid_meta <= 1'b0;
        display_valid_sync <= 1'b0;
        slot_meta <= 2'd0;
        slot_sync <= 2'd0;
        frame_slot <= 2'd0;
        vs_d <= 1'b0;
        frame_monitor_active <= 1'b0;
        pixel_count <= 19'd0;
        frame_signature <= 32'd0;
        baseline_signature[0] <= 32'd0;
        baseline_signature[1] <= 32'd0;
        baseline_signature[2] <= 32'd0;
        baseline_valid <= 3'b000;
        underflow_count <= 16'd0;
        underflow_sticky <= 1'b0;
        mismatch_count <= 16'd0;
        mismatch_sticky <= 1'b0;
    end else begin
        display_valid_meta <= display_valid_async;
        display_valid_sync <= display_valid_meta;
        slot_meta <= display_slot_async;
        slot_sync <= slot_meta;
        vs_d <= vs;

        if (display_valid_sync && fifo_read_req && fifo_empty) begin
            underflow_sticky <= 1'b1;
            if (underflow_count != 16'hffff)
                underflow_count <= underflow_count + 1'b1;
        end

        if (frame_start) begin
            // 先检查刚结束的帧，再为下一帧清零并锁存槽号。
            if (frame_monitor_active && (frame_slot < 2'd3)) begin
                if (pixel_count != EXPECTED_PIXEL_COUNT) begin
                    mismatch_sticky <= 1'b1;
                    if (mismatch_count != 16'hffff)
                        mismatch_count <= mismatch_count + 1'b1;
                end else if (!baseline_valid[frame_slot]) begin
                    baseline_signature[frame_slot] <= frame_signature;
                    baseline_valid[frame_slot] <= 1'b1;
                end else if (frame_signature != baseline_signature[frame_slot]) begin
                    mismatch_sticky <= 1'b1;
                    if (mismatch_count != 16'hffff)
                        mismatch_count <= mismatch_count + 1'b1;
                end
            end

            frame_monitor_active <= display_valid_sync;
            frame_slot <= slot_sync;
            pixel_count <= 19'd0;
            frame_signature <= 32'd0;
        end else if (frame_monitor_active && fifo_valid) begin
            frame_signature <= signature_next;
            if (pixel_count != 19'h7ffff)
                pixel_count <= pixel_count + 1'b1;
        end
    end
end

endmodule
