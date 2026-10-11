`timescale 1ns/1ps
// 全值域报告结果对照优化前实现；顺序处理期间禁止泄露半条轨道结果。
module tb_touch_lane_resource_equivalence;
reg clk=0;always #10 clk=~clk;
reg rst=1,enable=0,update=0,ad=0,bd=0;
reg [3:0] ai=0,bi=8;
reg [15:0] ax=0,ay=0,bx=0,by=0;
wire [13:0] actual,expected;
`define PORTS(bus) .clk(clk),.rst(rst),.enable(enable),.update_valid(update), \
    .a_id(ai),.a_down(ad),.a_x(ax),.a_y(ay),.b_id(bi),.b_down(bd),.b_x(bx),.b_y(by), \
    .event_valid(bus[13]),.armed(bus[12]),.press_mask(bus[11:8]),.release_mask(bus[7:4]),.down_mask(bus[3:0])
touch_lane_input dut(`PORTS(actual));
touch_lane_input_reference reference(`PORTS(expected));
`undef PORTS
integer cycles=0,i;reg [31:0] rng=32'h91471;reg [13:0] snapshot;reg [3:0] old_down;
always @(negedge clk)if(!rst)cycles=cycles+1;
task report;begin
    @(negedge clk);update=1;@(negedge clk);update=0;
    snapshot=expected;
    old_down=actual[3:0];
    repeat(11)begin
        @(negedge clk);
        if(actual[13] || actual[3:0]!==old_down)$fatal(1,"partial lane report leaked");
    end
    @(negedge clk);
    if(actual!==snapshot)$fatal(1,"serialized report mismatch %h/%h at %0d",actual,snapshot,cycles);
end endtask
initial begin
    repeat(4)@(negedge clk);rst=0;enable=1;repeat(4)@(negedge clk);
    ad=1;ay=8000;
    for(i=0;i<65536;i=i+1)begin ai=i[3:0];ax=i[15:0];report;end
    ax=3000;
    for(i=0;i<65536;i=i+1)begin ai=i[3:0];ay=i[15:0];report;end
    // 两指随机移动、编号、停用/复位；无需假设每次都是新的接触。
    for(i=0;i<10000;i=i+1)begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        ad=rng[0];bd=rng[1];ai=rng[5:2];bi=rng[9:6];
        ax=rng[15:0];ay=rng[31:16];bx=rng[31:16];by=rng[15:0];
        enable=(i%17)!=0;rst=(i%127)==0;report;
    end
    rst=0;repeat(4)@(negedge clk);
    $display("PASS lane resource equivalence: 131072 coordinate reports, 10000 state reports, %0d cycles",cycles);$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
