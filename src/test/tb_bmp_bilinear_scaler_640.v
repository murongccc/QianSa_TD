`timescale 1ns/1ps

module scaler_linebuf_even_ip(
    input wire [23:0] dia, input wire [10:0] addra, input wire cea,
    input wire clka, output reg [23:0] dob, input wire [10:0] addrb,
    input wire clkb, input wire rstb
);
    reg [23:0] mem [0:2047];
    always @(posedge clka) if (cea) mem[addra] <= dia;
    always @(posedge clkb) if (rstb) dob <= 24'd0; else dob <= mem[addrb];
endmodule

module scaler_linebuf_odd_ip(
    input wire [23:0] dia, input wire [10:0] addra, input wire cea,
    input wire clka, output reg [23:0] dob, input wire [10:0] addrb,
    input wire clkb, input wire rstb
);
    reg [23:0] mem [0:2047];
    always @(posedge clka) if (cea) mem[addra] <= dia;
    always @(posedge clkb) if (rstb) dob <= 24'd0; else dob <= mem[addrb];
endmodule

module tb_bmp_bilinear_scaler_640;
    reg clk=1'b0, rst=1'b1, start=1'b0, abort=1'b0;
    reg src_valid=1'b0, src_last=1'b0, src_frame_last=1'b0;
    reg [23:0] src_pixel=24'd0;
    reg dst_ready=1'b1;
    wire src_ready, dst_valid, dst_last, dst_frame_last, busy, done;
    wire [23:0] dst_pixel;
    wire [9:0] dst_x, dst_y;
    integer in_count=0, out_count=0, row, col;
    reg [23:0] expected;

    always #5 clk=~clk;

    bmp_bilinear_scaler #(.OUT_WIDTH(640),.OUT_HEIGHT(480)) dut(
        .clk(clk),.rst(rst),.start(start),.abort(abort),
        .src_width(16'd640),.src_height(16'd480),
        .src_valid(src_valid),.src_pixel(src_pixel),.src_last(src_last),
        .src_frame_last(src_frame_last),.src_ready(src_ready),
        .dst_ready(dst_ready),.dst_valid(dst_valid),.dst_pixel(dst_pixel),
        .dst_last(dst_last),.dst_frame_last(dst_frame_last),
        .dst_x(dst_x),.dst_y(dst_y),.busy(busy),.done(done)
    );

    always @(negedge clk) begin
        if (!rst && dst_valid && dst_ready) begin
            expected={dst_y[7:0],dst_x[7:0],dst_y[7:0]^dst_x[7:0]};
            if (dst_pixel !== expected)
                $fatal(1,"pixel mismatch at %0d,%0d: got %h expected %h",
                       dst_x,dst_y,dst_pixel,expected);
            if (dst_last !== (dst_x==10'd639))
                $fatal(1,"line-last mismatch at %0d,%0d",dst_x,dst_y);
            if (dst_frame_last !== ((dst_x==10'd639)&&(dst_y==10'd479)))
                $fatal(1,"frame-last mismatch at %0d,%0d",dst_x,dst_y);
            out_count=out_count+1;
        end
    end

    initial begin
        repeat(4) @(negedge clk);
        rst=1'b0;
        @(negedge clk); start=1'b1;
        @(negedge clk); start=1'b0;
        for(row=0;row<480;row=row+1) begin
            for(col=0;col<640;col=col+1) begin
                @(negedge clk);
                src_pixel={row[7:0],col[7:0],row[7:0]^col[7:0]};
                src_last=(col==639);
                src_frame_last=(col==639)&&(row==479);
                src_valid=1'b1;
                while(!src_ready) @(negedge clk);
                in_count=in_count+1;
            end
        end
        @(negedge clk);
        src_valid=1'b0;src_last=1'b0;src_frame_last=1'b0;
        wait(done);
        if(in_count!=307200 || out_count!=307200)
            $fatal(1,"frame count mismatch: in=%0d out=%0d",in_count,out_count);
        $display("PASS 640x480 scaler: 307200 exact pixels and frame completion");
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1,"640x480 scaler timeout: in=%0d out=%0d x=%0d y=%0d",
               in_count,out_count,dst_x,dst_y);
    end
endmodule
