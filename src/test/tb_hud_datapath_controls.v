`timescale 1ns/1ps
module tb_hud_datapath_controls;
parameter integer BLOCK=1,STREAM=1,TEXT=1;
reg clk=0,rst=1,frame_start=0;
reg [3:0] state=2,error_code=0;
reg auto_mode=0,metadata_valid=0;
reg [7:0] metadata_data=0;
reg [19:0] score=0;
reg [15:0] combo=0,max_combo=0,perfect_count=0,good_count=0,bad_count=0,miss_count=0;
reg [191:0] title=192'h4142434445464748494a4b4c4d4e4f505152535455565758;
reg [127:0] difficulty=128'h444946464943554c5459313233343536;
reg [9:0] x=0,y=0;
wire area,ref_area;
wire [9:0] rx,ry,ref_rx,ref_ry;
wire [7:0] character,ref_character;
wire [5:0] meta,ref_meta;
integer cycle=0,frame=0,checks=0;
always #5 clk=~clk;
rhythm_hud #(.BLOCK_CHARACTERS(BLOCK),.STREAM_METADATA(STREAM),.TEXT_ROM(TEXT)) dut(
 .clk(clk),.rst(rst),.frame_start(frame_start),.state(state),.error_code(error_code),.auto_mode(auto_mode),
 .score(score),.combo(combo),.max_combo(max_combo),.perfect_count(perfect_count),.good_count(good_count),.bad_count(bad_count),.miss_count(miss_count),
 .metadata_valid(metadata_valid),.metadata_data(metadata_data),.metadata_address(meta),.title(title),.difficulty(difficulty),
 .x(x),.y(y),.text_area(area),.rel_x(rx),.rel_y(ry),.character(character));
baseline_rhythm_hud #(.BLOCK_CHARACTERS(BLOCK),.STREAM_METADATA(STREAM),.TEXT_ROM(TEXT)) reference_dut(
 .clk(clk),.rst(rst),.frame_start(frame_start),.state(state),.error_code(error_code),.auto_mode(auto_mode),
 .score(score),.combo(combo),.max_combo(max_combo),.perfect_count(perfect_count),.good_count(good_count),.bad_count(bad_count),.miss_count(miss_count),
 .metadata_valid(metadata_valid),.metadata_data(metadata_data),.metadata_address(ref_meta),.title(title),.difficulty(difficulty),
 .x(x),.y(y),.text_area(ref_area),.rel_x(ref_rx),.rel_y(ref_ry),.character(ref_character));
always @(posedge clk)begin
 if({area,rx,ry,character,meta} !== {ref_area,ref_rx,ref_ry,ref_character,ref_meta})
  $fatal(1,"HUD output mismatch cycle=%0d",cycle);
 if(dut.character_we!==reference_dut.character_we)
  $fatal(1,"HUD write enable mismatch");
 if(dut.character_we && {dut.address,dut.character_write} !== {reference_dut.address,reference_dut.character_write})
  $fatal(1,"HUD character write mismatch cycle=%0d",cycle);
 if(!rst && !frame_start && (dut.phase==3 || (dut.phase==2 && dut.left!=0)))
  if(dut.bcd!==reference_dut.bcd)$fatal(1,"HUD BCD consumption mismatch");
 checks=checks+1;
end
initial begin
 // 一整幅坐标范围；每 700 拍重建，期间穿插短帧与中途复位。
 for(cycle=0;cycle<500000;cycle=cycle+1)begin
  @(negedge clk);
  rst=(cycle<3 || cycle%9973==400 || cycle%9973==401);
  frame_start=(cycle%700==5 || (cycle%9973>=100 && cycle%9973<=300 && cycle%17==0));
  x=cycle%1024;y=(cycle/1024)%480;
  metadata_valid=(cycle%5!=0);metadata_data={2'b01,meta};
  if(frame_start)begin
   frame=frame+1;state=frame%16;error_code=(frame/3)%16;auto_mode=frame%2;
   score=frame%3==0 ? 20'hfffff : (frame*7919)&20'hfffff;
   combo=frame*17;max_combo=frame*127;perfect_count=frame*31;
   good_count=frame*61;bad_count=frame*97;miss_count=frame*113;
  end
 end
 $display("PASS HUD datapath BLOCK=%0d STREAM=%0d TEXT=%0d cycles=%0d frames=%0d",BLOCK,STREAM,TEXT,checks,frame);
 $finish;
end
initial begin #6000000;$fatal(1,"HUD timeout");end
endmodule
