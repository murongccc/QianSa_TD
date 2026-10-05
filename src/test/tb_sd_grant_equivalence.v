`timescale 1ns/1ps
// 穷举请求、紧急标志及公平历史，独立旧优先公式检查归属和完整地址。
module tb_sd_grant_equivalence;
reg clk=0,rst=1,breq=0,areq=0,creq=0,urgent=0;
reg [31:0] ba=32'hfedc_ba98,aa=32'h0123_4567,ca=32'ha5a5_5a5a;
wire req;wire [31:0] addr;
reg old_audio,old_chart,old_bmp;
reg [31:0] expected_address;
integer vector_index;
always #5 clk=~clk;
sd_sector_arbiter #(.ENABLE_CHART(1),.REGISTER_RESPONSE(1)) dut(
 .clk(clk),.rst(rst),.bmp_req(breq),.bmp_addr(ba),.audio_req(areq),.audio_addr(aa),
 .audio_urgent(urgent),.sd_req(req),.sd_addr(addr),.sd_valid(1'b0),.sd_done(1'b0),
 .bmp_valid(),.bmp_done(),.audio_valid(),.audio_done(),.chart_req(creq),.chart_addr(ca),
 .chart_valid(),.chart_done(),.sd_data(8'd0),.response_data(),.response_busy());
initial begin
 repeat(2)@(negedge clk);rst=0;
 for(vector_index=0;vector_index<64;vector_index=vector_index+1)begin
  @(negedge clk);
  dut.state=2'd0;dut.last_audio=vector_index[4];dut.last_chart=vector_index[5];
  breq=vector_index[0];areq=vector_index[1];creq=vector_index[2];urgent=vector_index[3];
  old_audio=areq && (urgent || (!(breq || creq)) || !vector_index[4]);
  old_chart=!old_audio && creq && (!breq || !vector_index[5]);
  old_bmp=!old_audio && !old_chart;
  expected_address=old_audio ? aa : (old_chart ? ca : ba);
  @(posedge clk);#1;
  if(breq || areq || creq)begin
   if(!req || addr!==expected_address || dut.owner_audio!==old_audio || dut.owner_chart!==old_chart || dut.owner_bmp!==old_bmp)
    $fatal(1,"grant equivalence failed vector=%0d address=%h",vector_index,addr);
  end else if(req)$fatal(1,"request launched without client");
 end
 $display("PASS grant equivalence: all 64 request/urgent/history combinations and 32-bit addresses");
 $finish;
end
endmodule
