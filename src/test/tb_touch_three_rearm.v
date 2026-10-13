`timescale 1ns/1ps
module tb_touch_three_rearm;
reg clk=0;always #10 clk=~clk;
reg rst=1,bv=0,enable=1;reg [7:0] data=0;
wire update,ad,bd,cd,all_down,valid,armed;wire [3:0] ai,bi,ci,p,r,d;
wire [15:0] ax,ay,bx,by,cx,cy;
ch9350_touch_parser parser(.clk(clk),.rst(rst),.byte_valid(bv),.byte_data(data),.byte_error(1'b0),
 .ack_request(),.update_valid(update),.a_id(ai),.a_down(ad),.a_x(ax),.a_y(ay),
 .b_id(bi),.b_down(bd),.b_x(bx),.b_y(by),.c_id(ci),.c_down(cd),.c_x(cx),.c_y(cy),.all_down(all_down),
 .press_mask(),.release_mask(),.frame_seq(),.good_count(),.checksum_error_count(),.format_error_count(),
 .sequence_gap_count(),.timeout_count(),.uart_error_count());
touch_lane_input lane(clk,rst,enable,update,ai,ad,ax,ay,bi,bd,bx,by,valid,p,r,d,armed,ci,cd,cx,cy,all_down);
reg [7:0] frame[0:60];integer seq=0,events=0,k,i;reg [7:0] sum;reg [15:0] x;
always @(negedge clk)if(valid)events=events+1;
task byte;input [7:0] v;begin @(negedge clk);data=v;bv=1;@(negedge clk);bv=0;end endtask
task report;input [3:0] held;input [3:0] expected;begin
 for(i=0;i<61;i=i+1)frame[i]=0;
 frame[0]=87;frame[1]=171;frame[2]=136;frame[3]=57;frame[4]=64;frame[5]=13;
 for(i=0;i<4;i=i+1)begin
  x=1500+2000*i;frame[6+5*i]=((i+1)<<4)|held[i];frame[7+5*i]=x[7:0];frame[8+5*i]=x[15:8];
  frame[9+5*i]=8'h40;frame[10+5*i]=8'h1f;
 end
 frame[58]=4;frame[59]=seq;seq=seq+1;sum=0;
 for(i=5;i<60;i=i+1)sum=sum+frame[i];frame[60]=sum;
 for(i=0;i<61;i=i+1)byte(frame[i]);repeat(43)@(negedge clk);
 if(d!==expected)$fatal(1,"rearm down %h expected %h",d,expected);
end endtask
integer before_events;
initial begin
 repeat(4)@(negedge clk);rst=0;wait(armed);
 // 四种会话清空均由现有 enable 门控；必须等包含忽略触点的全松开。
 for(k=0;k<4;k=k+1)begin
  report(0,0);report(7,7);report(15,7);
  enable=0;repeat(5)@(negedge clk);before_events=events;report(8,0);
  if(ad || bd || cd || !all_down)$fatal(1,"ignored lifecycle not retained");
  enable=1;repeat(20)@(negedge clk);
  if(armed || d)$fatal(1,"ignored held finger rearmed session %d",k);
  report(8,0);if(armed || events!=before_events)$fatal(1,"held ignored finger manufactured press");
  report(0,0);wait(armed);report(7,7);report(0,0);
 end
 report(7,7);report(15,7);report(8,0);
 byte(87);byte(171);byte(130);byte(8'ha3);repeat(25)@(negedge clk);
 if(all_down || ad || bd || cd || d)$fatal(1,"module reconnect kept ignored finger");
 report(7,7);rst=1;repeat(3)@(negedge clk);rst=0;repeat(3)@(negedge clk);
 if(all_down || d)$fatal(1,"reset kept touch");
 $display("PASS pause/restart/cancel/mode enable gate, ignored-only held rearm, all-up, module reconnect and reset");$finish;
end
initial begin #2000000;$fatal(1,"timeout");end
endmodule
