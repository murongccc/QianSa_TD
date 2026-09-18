`timescale 1ns/1ps

// SDRAM 手动刷新调度器。
// 在刷新截止前提前请求，并阻止新的用户 burst，直到 IP 用
// sdr_init_ref_vld 确认刷新已经被接受。已启动的 burst 不会被中断。
module sdram_refresh_scheduler #(
    // 100 MHz 下 2500 周期为 25.0 us。刷新请求由外部实例可覆盖，
    // 默认值保持与当前板级手动刷新策略一致。
    parameter [13:0] REFRESH_INTERVAL_CYCLES = 14'd2500,
    parameter [13:0] EARLY_GUARD_CYCLES      = 14'd512
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sdr_init_done,
    input  wire        sdr_init_ref_vld,
    output reg         app_ref_req,
    output reg         refresh_hold,
    output reg         refresh_fault,
    output reg [13:0]  refresh_max_gap
);

localparam [13:0] REQUEST_START_CYCLES = REFRESH_INTERVAL_CYCLES - EARLY_GUARD_CYCLES;

reg        refresh_active;
reg        sdr_init_ref_vld_d0;
reg [13:0] refresh_gap;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        refresh_active       <= 1'b0;
        sdr_init_ref_vld_d0 <= 1'b0;
        refresh_gap          <= 14'd0;
        refresh_max_gap      <= 14'd0;
        app_ref_req          <= 1'b0;
        refresh_hold         <= 1'b0;
        refresh_fault        <= 1'b0;
    end else begin
        sdr_init_ref_vld_d0 <= sdr_init_ref_vld;

        if (!sdr_init_done) begin
            refresh_active       <= 1'b0;
            refresh_gap          <= 14'd0;
            refresh_max_gap      <= 14'd0;
            app_ref_req          <= 1'b0;
            refresh_hold         <= 1'b0;
            refresh_fault        <= 1'b0;
        end else if (!refresh_active) begin
            // 初始化阶段的 ref_vld 结束后才开始测量刷新间隔。
            if (!sdr_init_ref_vld) begin
                refresh_active  <= 1'b1;
                refresh_gap     <= 14'd0;
                refresh_max_gap <= 14'd0;
            end
            app_ref_req  <= 1'b0;
            refresh_hold <= 1'b0;
        end else if (sdr_init_ref_vld && !sdr_init_ref_vld_d0) begin
            // ref_vld 上升沿表示本次 App_ref_req 已被控制器接受。
            app_ref_req  <= 1'b0;
            refresh_gap  <= 14'd0;
            // 一旦发生过超限，不再恢复用户访问；迟到的刷新只能结束请求，
            // 不能证明此前 SDRAM 内容仍然可靠。
            if (refresh_fault)
                refresh_hold <= 1'b1;
            else
                refresh_hold <= 1'b0;
        end else begin
            if (refresh_gap != 14'h3fff)
                refresh_gap <= refresh_gap + 1'b1;

            if (refresh_gap > refresh_max_gap)
                refresh_max_gap <= refresh_gap;

            // 工程实际使用 256-word burst；另为读数据尾部、状态机切换和
            // 控制器接受 App_ref_req 预留余量，避免刷新确认越过截止点。
            if (refresh_gap >= REQUEST_START_CYCLES) begin
                app_ref_req  <= 1'b1;
                refresh_hold <= 1'b1;
            end

            // 到期仍未确认时永久停止再发起新访问，避免继续传播坏数据。
            if (refresh_gap >= REFRESH_INTERVAL_CYCLES)
                refresh_fault <= 1'b1;
        end
    end
end

endmodule
