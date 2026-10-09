`timescale 1ns/1ps
module tb_touch_marker;
reg active=0;
reg [9:0] x=0,y=0;
reg [39:0] packet=0;
wire a_hit,b_hit;
integer xi,yi,scenario,checks=0;
integer ax,ay,bx,by;
reg ad,bd;
touch_marker dut(.active(active),.pixel_x(x),.pixel_y(y),.frame_packet(packet),.a_hit(a_hit),.b_hit(b_hit));
function expected_hit;
    input integer px,py,cx,cy;
    input down;
    integer dx,dy;
    begin
        dx=px-cx;dy=py-cy;if(dx<0)dx= -dx;if(dy<0)dy= -dy;
        expected_hit=active && down && px<640 && py<480 && ((dx==0 && dy<=15) || (dy==0 && dx<=15));
    end
endfunction
task check;
    begin
        #1;
        if(a_hit!==expected_hit(x,y,ax,ay,ad) || b_hit!==expected_hit(x,y,bx,by,bd))begin
            $display("FAIL marker x=%0d y=%0d scenario=%0d",x,y,scenario);$stop;
        end
        checks=checks+1;
    end
endtask
initial begin
    for(scenario=0;scenario<5;scenario=scenario+1)begin
        case(scenario)
            0:begin ax=0;ay=0;bx=639;by=479;ad=1;bd=1;end
            1:begin ax=319;ay=241;bx=310;by=226;ad=1;bd=1;end
            2:begin ax=320;ay=240;bx=320;by=240;ad=1;bd=1;end
            3:begin ax=0;ay=479;bx=639;by=0;ad=0;bd=1;end
            default:begin ax=0;ay=479;bx=639;by=0;ad=0;bd=0;end
        endcase
        packet={ad,bd,ax[9:0],ay[8:0],bx[9:0],by[8:0]};active=1;
        for(yi=0;yi<480;yi=yi+1)for(xi=0;xi<640;xi=xi+1)begin x=xi[9:0];y=yi[9:0];check;end
        active=0;x=ax[9:0];y=ay[9:0];check;
        active=1;x=10'd1023;y=10'd1023;check;
    end
    $display("PASS marker: %0d pixel checks, two colors masks, overlap, release, clipping and blanking",checks);
    $finish;
end
endmodule
