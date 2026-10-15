`timescale 1ns/1ps

// 实际读写状态机相连：FIFO 恰在读 burst 获准时达到写阈值，不能双向同时发命令。
module tb_frame_burst_mutual_exclusion #(
    parameter integer BURST_WORDS=4
);
localparam integer FRAME_WORDS=BURST_WORDS*2;
localparam [20:0] FRAME_LENGTH=FRAME_WORDS;
reg clk=0,rst=1,read_req=0,write_req=0;
reg [9:0] write_words=0;
reg [2:0] read_return=0;
reg sdr_busy=0;
wire read_ack,write_ack,read_busy,write_busy,rd_en,wr_en,read_finish,write_finish;
integer reads=0,writes=0,cycles=0,scenario;
always #5 clk=~clk;
frame_fifo_read #(.ADDR_BITS(21),.BURST_BITS(9),.FIFO_DEPTH(512),.BURST_SIZE(BURST_WORDS)) rd(
    .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(sdr_busy),
    .refresh_hold(1'b0),.Sdr_rd_en(read_return[2]),.App_wr_busy(write_busy),.O_rd_busy(read_busy),
    .App_rd_en(rd_en),.App_rd_addr(),.read_req(read_req),.read_req_ack(read_ack),.read_finish(read_finish),
    .read_addr_0(21'd0),.read_addr_1(21'd0),.read_addr_2(21'd0),.read_addr_3(21'd0),.read_addr_4(21'd0),
    .read_addr_index(3'd0),.read_len(FRAME_LENGTH),.fifo_aclr(),.wrusedw(10'd0));
frame_fifo_write #(.ADDR_BITS(21),.BURST_BITS(9),.BURST_SIZE(BURST_WORDS),.FRAME_WIDTH(BURST_WORDS),.FRAME_HEIGHT(2)) wr(
    .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(sdr_busy),
    .refresh_hold(1'b0),.App_rd_busy(read_busy),.O_wr_busy(write_busy),.App_wr_en(wr_en),.App_wr_addr(),
    .write_req(write_req),.write_req_ack(write_ack),.write_finish(write_finish),
    .write_addr_0(21'd64),.write_addr_1(21'd0),.write_addr_2(21'd0),.write_addr_3(21'd0),.write_addr_4(21'd0),
    .write_addr_index(3'd0),.write_len(FRAME_LENGTH),.write_v_flip(1'b0),.fifo_aclr(),.rdusedw(write_words));
always @(posedge clk) begin
    if(rst)begin read_return<=0;sdr_busy<=0;reads=0;writes=0;cycles=0;end
    else begin
        read_return<={read_return[1:0],rd_en};
        // 控制器在采到请求后才置 busy，不能拿 busy 代替客户端之间的互斥。
        sdr_busy<=rd_en || wr_en || (|read_return);
        if(rd_en && wr_en)$fatal(1,"overlapping SDRAM read/write commands at cycle %0d",cycles);
        if(rd_en)reads=reads+1;
        if(wr_en)writes=writes+1;
        cycles=cycles+1;
    end
end
initial begin
    for(scenario=0;scenario<3;scenario=scenario+1)begin
        rst=1;read_req=0;write_req=0;write_words=0;
        repeat(3)@(negedge clk);rst=0;
        if(scenario==0)write_words=BURST_WORDS+1;
        read_req=1;write_req=1;
        wait(read_ack && write_ack);
        @(negedge clk);read_req=0;write_req=0;
        wait(rd.state==2 && wr.state==2);
        if(scenario==2)repeat(2)@(negedge clk);
        @(negedge clk);write_words=BURST_WORDS+1;
        wait(reads>=FRAME_WORDS && writes>=FRAME_WORDS);
        repeat(6)@(negedge clk);
        if(reads!=FRAME_WORDS || writes!=FRAME_WORDS)$fatal(1,"wrong command counts read=%0d write=%0d",reads,writes);
    end
    $display("PASS frame burst mutual exclusion: burst=%0d, 3 FIFO phases, both directions complete",BURST_WORDS);
    $finish;
end
initial begin #200000;$fatal(1,"burst arbitration timeout read=%0d write=%0d",reads,writes);end
endmodule
