/************************************************************\
**	Copyright (c) 2012-2025 Anlogic Inc.
**	All Right Reserved.
\************************************************************/
/************************************************************\
**	Build time: Sep 13 2026 20:58:24
**	TD version	:	6.2.168116
************************************************************/
`timescale 1ns/1ps
module source_pixel_fifo_ip
(
  input                         srst,
  input   [31:0]                di,
  input                         clk,
  input                         re,
  input                         we,
  output  [31:0]                dout,
  output                        empty_flag,
  output                        aempty,
  output                        full_flag,
  output                        afull,
  output                        valid,
  output                        overflow,
  output                        underflow,
  output                        wr_success,
  output  [9:0]                 rdusedw,
  output  [9:0]                 wrusedw,
  output                        wr_rst_done,
  output                        rd_rst_done
);

  soft_fifo_f9a960ae4922
  #(
      .COMMON_CLK_EN(1),
      .MEMORY_TYPE(3),
      .RST_TYPE(2),
      .DATA_WIDTH_W(32),
      .ADDR_WIDTH_W(9),
      .DATA_WIDTH_R(32),
      .ADDR_WIDTH_R(9),
      .DOUT_INITVAL(32'h0),
      .OUTREG_EN("NOREG"),
      .SHOW_AHEAD_EN(1),
      .AL_FULL_NUM(448),
      .AL_EMPTY_NUM(2),
      .RDUSEDW_WIDTH(10),
      .WRUSEDW_WIDTH(10),
      .ASYNC_RST_SYNC_RELS(0),
      .SYNC_STAGE(2)
  )soft_fifo_f9a960ae4922_Inst
  (
      .srst(srst),
      .di(di),
      .clk(clk),
      .re(re),
      .we(we),
      .dout(dout),
      .empty_flag(empty_flag),
      .aempty(aempty),
      .full_flag(full_flag),
      .afull(afull),
      .valid(valid),
      .overflow(overflow),
      .underflow(underflow),
      .wr_success(wr_success),
      .rdusedw(rdusedw),
      .wrusedw(wrusedw),
      .wr_rst_done(wr_rst_done),
      .rd_rst_done(rd_rst_done)
  );
endmodule
