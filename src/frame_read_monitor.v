`timescale 1ns/1ps

// 视频帧读出诊断：分别记录 FIFO 空读和同槽帧数据变化。
// 所有计数仅在 display_valid 后工作，避免把上电装载阶段计为故障。
module frame_read_monitor #(
    parameter integer FRAME_PIXELS = 307200,
    parameter integer SIGNATURE_CHECK = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        display_valid_async,
    input  wire [2:0]  display_slot_async,
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
reg [2:0]  slot_meta, slot_sync, frame_slot;
reg        vs_d;
reg        frame_monitor_active;
reg [18:0] pixel_count;
reg [31:0] frame_signature;
// 基线内容不复位，只复位有效位；使用有余量的 BRAM32K，保留 BRAM9K 余量。
// 帧槽号在整帧期间稳定，同步读出的基线在帧结束前已准备好，不生成新 IP。
wire [31:0] baseline_read;
reg [4:0]  baseline_valid;

wire frame_start = vs && !vs_d;
wire [31:0] signature_next = {frame_signature[30:0], frame_signature[31]} ^
                             fifo_data ^ {13'd0, pixel_count};

wire baseline_write = !rst && frame_start && frame_monitor_active &&
                      frame_slot < 3'd5 && pixel_count == EXPECTED_PIXEL_COUNT &&
                      !baseline_valid[frame_slot];
generate
if (SIGNATURE_CHECK != 0) begin : g_baseline_ram
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(32),.DATA_WIDTH_B(32),.ADDR_WIDTH_A(3),.ADDR_WIDTH_B(3),
        .DATA_DEPTH_A(8),.DATA_DEPTH_B(8),.MODE("PDPW"),.IMPLEMENT("32K"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),
        .WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),.INIT_FILE("NONE"),.FILL_ALL("NONE")
    ) baseline_ram (
        .dia(frame_signature),.dib(32'd0),.addra(frame_slot),.addrb(frame_slot),
        .cea(baseline_write),.ceb(1'b1),.ocea(1'b0),.oceb(1'b1),.clka(clk),.clkb(clk),
        .wea(1'b1),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),
        .doa(),.dob(baseline_read)
    );
end else begin : g_without_baseline_ram
    assign baseline_read = 32'd0;
end
endgenerate

always @(posedge clk or posedge rst) begin
    if (rst) begin
        display_valid_meta <= 1'b0;
        display_valid_sync <= 1'b0;
        slot_meta <= 3'd0;
        slot_sync <= 3'd0;
        frame_slot <= 3'd0;
        vs_d <= 1'b0;
        frame_monitor_active <= 1'b0;
        pixel_count <= 19'd0;
        frame_signature <= 32'd0;
        baseline_valid <= 5'b00000;
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

        if (SIGNATURE_CHECK && frame_start) begin
            // 先检查刚结束的帧，再为下一帧清零并锁存槽号。
            if (frame_monitor_active && (frame_slot < 3'd5)) begin
                if (pixel_count != EXPECTED_PIXEL_COUNT) begin
                    mismatch_sticky <= 1'b1;
                    if (mismatch_count != 16'hffff)
                        mismatch_count <= mismatch_count + 1'b1;
                end else if (!baseline_valid[frame_slot]) begin
                    baseline_valid[frame_slot] <= 1'b1;
                end else if (frame_signature != baseline_read) begin
                    mismatch_sticky <= 1'b1;
                    if (mismatch_count != 16'hffff)
                        mismatch_count <= mismatch_count + 1'b1;
                end
            end

            frame_monitor_active <= display_valid_sync;
            frame_slot <= slot_sync;
            pixel_count <= 19'd0;
            frame_signature <= 32'd0;
        end else if (SIGNATURE_CHECK && frame_monitor_active && fifo_valid) begin
            frame_signature <= signature_next;
            if (pixel_count != 19'h7ffff)
                pixel_count <= pixel_count + 1'b1;
        end
    end
end

endmodule

// 数码管每两秒只显示一个计数，共用采样器；源域的所有计数器始终独立运行。
// 页面切换后等待页号与数据同步流水线排空，防止把上一页数值配到新页。
module frame_diagnostic_sampler (
    input wire clk,input wire rst,input wire [2:0] page,
    input wire [15:0] count_b,count_d,count_f,count_c,count_a,
    output reg [15:0] count_display
);
wire [15:0] selected_count = (page == 3'd1) ? count_b :
                            (page == 3'd2) ? count_d :
                            (page == 3'd3) ? count_f :
                            (page == 3'd4) ? count_c : count_a;
reg [15:0] count_meta,count_sync,count_previous;
reg [2:0] page_d0,page_d1,page_d2;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        count_meta<=16'd0;count_sync<=16'd0;count_previous<=16'd0;count_display<=16'd0;
        page_d0<=3'd0;page_d1<=3'd0;page_d2<=3'd0;
    end else begin
        count_meta<=selected_count;
        count_sync<=count_meta;
        count_previous<=count_sync;
        page_d0<=page;page_d1<=page_d0;page_d2<=page_d1;
        if (page != page_d0)
            count_display<=16'd0;
        else if (page == page_d1 && page == page_d2 && count_sync == count_previous)
            count_display<=count_sync;
    end
end
endmodule

// 只轮换已启用的诊断页，避免把未实例化监视器的零值误当成正常测量。
module frame_diagnostic_pages #(
    parameter FIFO_ENABLED=1,parameter MEMORY_ENABLED=0,parameter OUTPUT_ENABLED=0
)(input wire [2:0] page,output reg [2:0] next_page);
always @* begin
    case(page)
        3'd0:next_page=3'd1;
        3'd1:next_page=OUTPUT_ENABLED ? 3'd2 : (FIFO_ENABLED ? 3'd3 : (MEMORY_ENABLED ? 3'd4 : 3'd5));
        3'd2:next_page=FIFO_ENABLED ? 3'd3 : (MEMORY_ENABLED ? 3'd4 : 3'd5);
        3'd3:next_page=MEMORY_ENABLED ? 3'd4 : 3'd5;
        3'd4:next_page=3'd5;
        default:next_page=3'd0;
    endcase
end
endmodule
