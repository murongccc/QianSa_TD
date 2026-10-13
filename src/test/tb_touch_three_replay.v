`timescale 1ns/1ps
module tb_touch_three_replay;
parameter integer FRAMES=523;
parameter FILE="touch_01_three_down_release";
reg clk=0;always #10 clk=~clk;
reg rst=1,bv=0;reg [7:0] data=0;
wire uv,ad,bd,cd,all_down,lv,armed;wire [3:0] ai,bi,ci,p,r,d;
wire [15:0] ax,ay,bx,by,cx,cy;
wire [15:0] good,ce,fe;
ch9350_touch_parser parser(.clk(clk),.rst(rst),.byte_valid(bv),.byte_data(data),.byte_error(1'b0),
 .update_valid(uv),.a_id(ai),.a_down(ad),.a_x(ax),.a_y(ay),.b_id(bi),.b_down(bd),.b_x(bx),.b_y(by),
 .c_id(ci),.c_down(cd),.c_x(cx),.c_y(cy),.all_down(all_down),.good_count(good),.checksum_error_count(ce),.format_error_count(fe),.ack_request(),.press_mask(),.release_mask(),.frame_seq(),.sequence_gap_count(),.timeout_count(),.uart_error_count());
touch_lane_input lane(.clk(clk),.rst(rst),.enable(1'b1),.update_valid(uv),
 .a_id(ai),.a_down(ad),.a_x(ax),.a_y(ay),.b_id(bi),.b_down(bd),.b_x(bx),.b_y(by),
 .c_id(ci),.c_down(cd),.c_x(cx),.c_y(cy),.all_down(all_down),
 .event_valid(lv),.press_mask(p),.release_mask(r),.down_mask(d),.armed(armed));
reg [7:0] bytes[0:61*FRAMES-1];reg [127:0] expected[0:FRAMES-1];
wire [111:0] snapshot={ai,ad,ax,ay,bi,bd,bx,by,ci,cd,cx,cy,all_down};
reg [111:0] previous_snapshot=0;reg [11:0] event_packet=0;
integer f,j,t,events=0,updates=0,start_events,start_updates,passed=0;
always @(negedge clk)if(!rst)begin
 if(!uv && snapshot!==previous_snapshot)$fatal(1,"partial parser publication frame %d",f);
 previous_snapshot=snapshot;
 if(uv)updates=updates+1;
 if(lv)begin events=events+1;event_packet={p,r,d};end
end
initial begin
 $readmemh({"src/test/data/",FILE,".hex"},bytes);$readmemh({"src/test/data/",FILE,".expected"},expected);
 repeat(4)@(negedge clk);rst=0;wait(armed);
 for(f=0;f<FRAMES;f=f+1)begin
  start_events=events;start_updates=updates;
  for(j=0;j<61;j=j+1)begin
   @(negedge clk);data=bytes[61*f+j];bv=1;@(negedge clk);bv=0;
  end
  // 校验字节之后20拍发布，39拍生成游戏事件；整个输入状态在此前保持。
  for(t=1;t<=42;t=t+1)begin
   @(negedge clk);#1;
   if(expected[f][124] && t<20 && updates!=start_updates)$fatal(1,"early publication");
   if(expected[f][124] && t==20 && !uv)$fatal(1,"parser latency %d",f);
   if(expected[f][124] && expected[f][11:4]!=0 && t==39 && !lv)$fatal(1,"lane latency %d",f);
  end
  if(updates!=start_updates+expected[f][124])$fatal(1,"valid count frame %d",f);
  if(snapshot!==expected[f][123:12] || d!==expected[f][3:0])
   $fatal(1,"snapshot frame %d got %h/%h expected %h",f,snapshot,d,expected[f]);
  if(events!=start_events+(expected[f][11:4]!=0))$fatal(1,"event count %d",f);
  if(expected[f][11:4]!=0 && event_packet!==expected[f][11:0])$fatal(1,"atomic event %d",f);
  passed=passed+1;
 end
 $display("PASS %0s %0d frames atomic parser 20 cycles + lane 19 cycles",FILE,passed);$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
