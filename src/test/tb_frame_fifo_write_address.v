`timescale 1ns/1ps

// 直接检查实际 App_wr_en/App_wr_addr 序列，覆盖行翻转、burst 间停顿和重新请求。
module tb_frame_fifo_write_address;
localparam FRAME_WIDTH=4, FRAME_HEIGHT=3, FRAME_WORDS=12;
reg clk=0,rst=1,write_req=0,write_v_flip=0;
wire app_wr_en,write_req_ack,write_finish;
wire [20:0] app_wr_addr;
integer accepted=0;
integer expected_row,expected_col,expected_addr;
always #5 clk=~clk;

frame_fifo_write #(.ADDR_BITS(21),.BURST_BITS(3),.BURST_SIZE(4),
    .BURST_COUNT_BITS(3),.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)) dut(
    .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),
    .Sdr_busy(1'b0),.refresh_hold(1'b0),.App_rd_busy(1'b0),.O_wr_busy(),
    .App_wr_en(app_wr_en),.App_wr_addr(app_wr_addr),.write_req(write_req),
    .write_req_ack(write_req_ack),.write_finish(write_finish),
    .write_addr_0(21'd100),.write_addr_1(21'd0),.write_addr_2(21'd0),
    .write_addr_3(21'd0),.write_addr_4(21'd0),.write_addr_index(3'd0),
    .write_len(21'd12),.write_v_flip(write_v_flip),.fifo_aclr(),.rdusedw(10'd12));

always @(posedge clk) if(app_wr_en)begin
    expected_row=accepted/FRAME_WIDTH;
    expected_col=accepted%FRAME_WIDTH;
    if(write_v_flip)expected_row=FRAME_HEIGHT-1-expected_row;
    expected_addr=100+expected_row*FRAME_WIDTH+expected_col;
    if(app_wr_addr!==expected_addr)
        $fatal(1,"address %0d got %0d expected %0d",accepted,app_wr_addr,expected_addr);
    accepted=accepted+1;
end

task run_frame;
 input flip;
 begin
    accepted=0;write_v_flip=flip;write_req=1;
    wait(write_req_ack);@(negedge clk);write_req=0;
    wait(write_finish);@(negedge clk);
    if(accepted!=FRAME_WORDS)$fatal(1,"word count %0d",accepted);
 end
endtask

initial begin
 repeat(3)@(negedge clk);rst=0;
 run_frame(1'b0);
 repeat(3)@(negedge clk);
 run_frame(1'b1);
 $display("PASS frame FIFO write addresses: linear and vertically flipped");
 $finish;
end
initial begin #20000;$fatal(1,"timeout");end
endmodule
