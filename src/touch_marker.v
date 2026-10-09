// 31x31、线宽一像素的双点十字判定；部分落在画面外时只裁剪，不环绕。
module touch_marker(
    input wire active,input wire [9:0] pixel_x,input wire [9:0] pixel_y,
    input wire [39:0] frame_packet,output wire a_hit,output wire b_hit
);
wire visible=active && pixel_x<10'd640 && pixel_y<10'd480;
function cross_hit;
    input [9:0] px,py,cx,cy;
    reg [5:0] hx,hy;
    reg near_x,near_y,center_x,center_y;
    begin
        // 半径15：同一16像素区间必相近，邻区间只需比较低4位，省去10位减法。
        // 有效画面内高位差为-39..39，模64的1/63分别唯一对应相邻区间。
        hx=px[9:4]-cx[9:4];hy=py[9:4]-cy[9:4];
        near_x=(hx==6'd0) || (hx==6'd1 && px[3:0]<cx[3:0]) || (hx==6'h3f && px[3:0]>cx[3:0]);
        near_y=(hy==6'd0) || (hy==6'd1 && py[3:0]<cy[3:0]) || (hy==6'h3f && py[3:0]>cy[3:0]);
        center_x=(hx==6'd0 && px[3:0]==cx[3:0]);center_y=(hy==6'd0 && py[3:0]==cy[3:0]);
        cross_hit=(center_x && near_y) || (center_y && near_x);
    end
endfunction
assign a_hit=visible && frame_packet[39] && cross_hit(pixel_x,pixel_y,frame_packet[37:28],{1'b0,frame_packet[27:19]});
assign b_hit=visible && frame_packet[38] && cross_hit(pixel_x,pixel_y,frame_packet[18:9],{1'b0,frame_packet[8:0]});
endmodule
