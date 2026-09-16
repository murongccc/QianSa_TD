`timescale 1ns/1ps

// Compile this testbench instead of the generated line-buffer wrappers.  The
// small behavioural memories model the registered B port used by the ERAM IP.
module scaler_linebuf_even_ip(
    input wire [23:0] dia, input wire [10:0] addra, input wire cea,
    input wire clka, output reg [23:0] dob, input wire [10:0] addrb,
    input wire clkb, input wire rstb
);
    reg [23:0] mem [0:2047];
    always @(posedge clka) if (cea) mem[addra] <= dia;
    always @(posedge clkb) begin
        if (rstb) dob <= 24'd0;
        else dob <= mem[addrb];
    end
endmodule

module scaler_linebuf_odd_ip(
    input wire [23:0] dia, input wire [10:0] addra, input wire cea,
    input wire clka, output reg [23:0] dob, input wire [10:0] addrb,
    input wire clkb, input wire rstb
);
    reg [23:0] mem [0:2047];
    always @(posedge clka) if (cea) mem[addra] <= dia;
    always @(posedge clkb) begin
        if (rstb) dob <= 24'd0;
        else dob <= mem[addrb];
    end
endmodule

module tb_bmp_bilinear_scaler;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg src_valid = 1'b0;
    reg [23:0] src_pixel = 24'd0;
    reg src_last = 1'b0;
    reg src_frame_last = 1'b0;
    reg dst_ready = 1'b1;
    wire src_ready, dst_valid, dst_last, dst_frame_last, busy, done;
    wire [23:0] dst_pixel;
    wire [9:0] dst_x, dst_y;
    integer output_count = 0;
    reg stall_active = 1'b0;
    reg [23:0] held_pixel;
    reg [9:0] held_x, held_y;
    reg held_last, held_frame_last;

    always #5 clk = ~clk;

    bmp_bilinear_scaler #(
        .OUT_WIDTH(4), .OUT_HEIGHT(4), .MAX_WIDTH(1920), .MAX_HEIGHT(1080)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .abort(1'b0),
        .src_width(16'd2), .src_height(16'd2),
        .src_valid(src_valid), .src_pixel(src_pixel),
        .src_last(src_last), .src_frame_last(src_frame_last),
        .src_ready(src_ready), .dst_ready(dst_ready),
        .dst_valid(dst_valid), .dst_pixel(dst_pixel),
        .dst_last(dst_last), .dst_frame_last(dst_frame_last),
        .dst_x(dst_x), .dst_y(dst_y), .busy(busy), .done(done)
    );

    task send_pixel;
        input [23:0] pixel;
        input line_last;
        input image_last;
        begin
            @(negedge clk);
            src_pixel = pixel;
            src_last = line_last;
            src_frame_last = image_last;
            src_valid = 1'b1;
            while (!src_ready) @(negedge clk);
            @(negedge clk);
            src_valid = 1'b0;
            src_last = 1'b0;
            src_frame_last = 1'b0;
        end
    endtask

    always @(negedge clk) begin
        if (!rst && dst_valid && dst_ready) begin
            if ((dst_x == 0) && (dst_y == 0) && (dst_pixel !== 24'hff0000))
                $fatal(1, "top-left corner changed: %h", dst_pixel);
            if ((dst_x == 3) && (dst_y == 0) && (dst_pixel !== 24'h00ff00))
                $fatal(1, "top-right corner changed: %h", dst_pixel);
            if ((dst_x == 0) && (dst_y == 3) && (dst_pixel !== 24'h0000ff))
                $fatal(1, "bottom-left corner changed: %h", dst_pixel);
            if ((dst_x == 3) && (dst_y == 3) && (dst_pixel !== 24'hffffff))
                $fatal(1, "bottom-right corner changed: %h", dst_pixel);
            if (dst_last !== (dst_x == 3))
                $fatal(1, "dst_last mismatch at %0d,%0d", dst_x, dst_y);
            if (dst_frame_last !== ((dst_x == 3) && (dst_y == 3)))
                $fatal(1, "dst_frame_last mismatch at %0d,%0d", dst_x, dst_y);
            output_count = output_count + 1;
        end

        if (!rst && dst_valid && !dst_ready) begin
            if (!stall_active) begin
                stall_active = 1'b1;
                held_pixel = dst_pixel;
                held_x = dst_x;
                held_y = dst_y;
                held_last = dst_last;
                held_frame_last = dst_frame_last;
            end else if ((dst_pixel !== held_pixel) || (dst_x !== held_x) ||
                         (dst_y !== held_y) || (dst_last !== held_last) ||
                         (dst_frame_last !== held_frame_last)) begin
                $fatal(1, "output changed while dst_ready was low");
            end
        end else begin
            stall_active = 1'b0;
        end
    end

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        send_pixel(24'hff0000, 1'b0, 1'b0);
        send_pixel(24'h00ff00, 1'b1, 1'b0);
        send_pixel(24'h0000ff, 1'b0, 1'b0);
        send_pixel(24'hffffff, 1'b1, 1'b1);

        wait(dst_valid && dst_x == 1 && dst_y == 1);
        @(negedge clk);
        dst_ready = 1'b0;
        repeat (4) @(negedge clk);
        dst_ready = 1'b1;

        wait(done);
        if (output_count != 16)
            $fatal(1, "expected 16 output pixels, got %0d", output_count);
        $display("PASS bmp_bilinear_scaler: corners, flags, completion, and output backpressure");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "scaler timeout: src_ready=%b out=%0d x=%0d y=%0d",
               src_ready, output_count, dst_x, dst_y);
    end
endmodule
