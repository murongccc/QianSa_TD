`timescale 1ns/1ps
module tb_frame_diagnostic_pages;
reg [2:0] all_page=0,f_page=0,c_page=0,d_page=0,off_page=0;
wire [2:0] all_next,f_next,c_next,d_next,off_next;
integer index;
reg [2:0] expected_f,expected_c,expected_d,expected_all,expected_off;
frame_diagnostic_pages #(.FIFO_ENABLED(1),.MEMORY_ENABLED(1),.OUTPUT_ENABLED(1))
    all_pages(.page(all_page),.next_page(all_next));
frame_diagnostic_pages f_pages(.page(f_page),.next_page(f_next));
frame_diagnostic_pages #(.FIFO_ENABLED(0),.MEMORY_ENABLED(1),.OUTPUT_ENABLED(0))
    c_pages(.page(c_page),.next_page(c_next));
frame_diagnostic_pages #(.FIFO_ENABLED(0),.MEMORY_ENABLED(0),.OUTPUT_ENABLED(1))
    d_pages(.page(d_page),.next_page(d_next));
frame_diagnostic_pages #(.FIFO_ENABLED(0),.MEMORY_ENABLED(0),.OUTPUT_ENABLED(0))
    off_pages(.page(off_page),.next_page(off_next));
initial begin
    for(index=0;index<36;index=index+1)begin
        #1;
        expected_all=index%6;
        case(index%4)
            0:begin expected_f=0;expected_c=0;expected_d=0;end
            1:begin expected_f=1;expected_c=1;expected_d=1;end
            2:begin expected_f=3;expected_c=4;expected_d=2;end
            default:begin expected_f=5;expected_c=5;expected_d=5;end
        endcase
        case(index%3)
            0:expected_off=0;
            1:expected_off=1;
            default:expected_off=5;
        endcase
        if({all_page,f_page,c_page,d_page,off_page} !==
           {expected_all,expected_f,expected_c,expected_d,expected_off})
            $fatal(1,"page sequence failed at %0d",index);
        all_page=all_next;f_page=f_next;c_page=c_next;d_page=d_next;off_page=off_next;
    end
    all_page=7;f_page=7;c_page=7;d_page=7;off_page=7;
    #1;
    if({all_next,f_next,c_next,d_next,off_next}!==15'd0)$fatal(1,"illegal page recovery failed");
    $display("PASS diagnostic pages: full/F/C/D/disabled sequences and illegal state recovery");
    $finish;
end
endmodule
