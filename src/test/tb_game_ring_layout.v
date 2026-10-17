`timescale 1ns/1ps
// 图片模式验证加宽后的像素边界；游戏模式逐像素对照修改前版本。
module tb_game_ring_layout;
parameter integer BLOCK_BARS=1;
reg clk=0,rst=1,game=0;
always #5 clk=~clk;
reg [9:0] x=0,y=0;
reg [7:0] radius=90,level=0;
reg [639:0] bars=0;
wire [6:0] address;
reg [7:0] data;
wire on,golden_on;
wire [23:0] rgb,golden_rgb;
always @(posedge clk)data<=bars[address*8+:8];
ring_spectrum_renderer #(.REFERENCE_MODE(1),.BLOCK_BARS(BLOCK_BARS),.ENABLE_GAME_LAYOUT(1)) dut(
    .clk(clk),.rst(rst),.breath_radius(radius),.pixel_x(x),.pixel_y(y),.bands(256'd0),.bars(bars),
    .bars_read_address(address),.bars_read_data(data),.bars_read_valid(1'b1),.bars_active(|bars),
    .game_layout(game),.pixel_on(on),.pixel_rgb(rgb));
baseline_ring_spectrum_renderer #(.REFERENCE_MODE(1),.ENABLE_GAME_LAYOUT(1)) golden(
    .game_layout(game),
    .clk(clk),.rst(rst),.breath_radius(radius),.pixel_x(x),.pixel_y(y),.bands(256'd0),.bars(bars),
    .bars_read_address(),.bars_read_data(8'd0),.bars_read_valid(1'b0),.bars_active(1'b0),
    .pixel_on(golden_on),.pixel_rgb(golden_rgb));
integer px,py,i,r,l,d,inner,length,width_limit,checks=0,hits=0,added=0;
reg expected;
initial begin
    repeat(4)@(negedge clk);rst=0;
    // 各柱不同幅度，覆盖真实同步缓存的地址/颜色对齐。
    for(i=0;i<80;i=i+1)bars[i*8+:8]=(i*37+11)%256;
    radius=110;
    for(py=0;py<480;py=py+1)for(px=0;px<640;px=px+1)begin
        @(negedge clk);x=px;y=py;
        @(posedge clk);#1;
        // 旧版几何、柱长和颜色作为基准，仅将横向误差边界扩大5/4。
        width_limit=(golden.side_limit*5)/4;
        expected=golden.active_stage && golden.cross_error<=width_limit &&
            golden.distance_sq_stage>=golden.base_radius_sq_stage &&
            golden.distance_sq_stage<=golden.outer_radius_sq &&
            (golden.distance_sq_stage>=golden.inner_cap_radius_sq || golden.cross_error<=width_limit/2) &&
            (golden.distance_sq_stage<=golden.cap_body_radius_sq || golden.cross_error<=width_limit/2);
        if(on!==expected || rgb!==golden_rgb)$fatal(1,"picture width mismatch at %d/%d",px,py);
        if(golden_on && !on)$fatal(1,"picture lost original pixel");
        if(on && !golden_on)added=added+1;
        if(dut.base_radius!==golden.base_radius || dut.bar_length!==golden.bar_length)
            $fatal(1,"picture radius or length changed");
        checks=checks+1;
    end
    if(added==0)$fatal(1,"picture bars did not widen");
    game=1;
    for(r=90;r<=110;r=r+1)for(l=0;l<256;l=l+1)begin
        radius=r;bars={80{l[7:0]}};
        inner=(r*2)/3;length=l/4;if(length<8)length=8;length=(length*3)/4;
        for(d=0;d<=124;d=d+1)begin
            @(negedge clk);x=488+d;y=240;
            @(posedge clk);#1;
            expected=l!=0 && d>=inner && d<=inner+length;
            if(on!==expected)$fatal(1,"small ring r/l/d=%d/%d/%d",r,l,d);
            if(d!=0 && address!==0)$fatal(1,"small ring cardinal index");
            checks=checks+1;
        end
    end
    radius=110;bars={80{8'd255}};
    for(py=0;py<480;py=py+1)for(px=0;px<640;px=px+1)begin
        @(negedge clk);x=px;y=py;
        @(posedge clk);#1;
        if(on!==golden_on || rgb!==golden_rgb)$fatal(1,"game pixels changed at %d/%d",px,py);
        if(on)begin
            hits=hits+1;
            if(px<368 || px>608 || py<120 || py>360 ||
                (px-488)*(px-488)+(py-240)*(py-240)>14400)
                $fatal(1,"small ring overflow at %d/%d",px,py);
        end
    end
    if(hits<5000)$fatal(1,"small ring missing bars %d",hits);
    game=0;x=440;y=240;
    @(posedge clk);#1;if(on!==golden_on || !on)$fatal(1,"normal layout did not restore");
    $display("PASS game ring: %0d exact checks, 21 radii/256 levels, 120px bounds, %0d visible pixels, cache mode=%0d",checks,hits,BLOCK_BARS);
    $finish;
end
initial begin #30000000;$fatal(1,"ring layout timeout");end
endmodule
