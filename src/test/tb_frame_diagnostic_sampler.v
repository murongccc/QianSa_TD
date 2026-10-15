`timescale 1ns/1ps
module tb_frame_diagnostic_sampler;
reg clk=0,rst=1;
reg [2:0] page=0;
reg [15:0] count_b=16'h1111,count_d=16'h2222,count_f=16'h3333,count_c=16'h4444,count_a=16'haaaa;
wire [15:0] shown;
integer index;
reg [15:0] expected;
always #10 clk=~clk;
frame_diagnostic_sampler dut(.clk(clk),.rst(rst),.page(page),
    .count_b(count_b),.count_d(count_d),.count_f(count_f),.count_c(count_c),.count_a(count_a),
    .count_display(shown));
task settle;
begin repeat(6) @(negedge clk);end
endtask
initial begin
    repeat(3) @(negedge clk);rst=0;
    for(index=0;index<60;index=index+1) begin
        page=(index%5)+1;
        case(page)
            1:expected=count_b;
            2:expected=count_d;
            3:expected=count_f;
            4:expected=count_c;
            default:expected=count_a;
        endcase
        settle;
        if(shown!==expected)$fatal(1,"wrong diagnostic page %0d: %h != %h",page,shown,expected);
        count_b=count_b+16'd17;count_d=count_d+16'd31;count_f=count_f+16'd7;
        count_c=count_c+16'd9;count_a=count_a+16'd1;
    end
    // 快速切页不能把旧页结果长期留到最终页面。
    repeat(12)begin page=page==5 ? 1 : page+1'b1;@(negedge clk);end
    page=3;settle;
    if(shown!==count_f)$fatal(1,"rapid page change left stale data");
    count_f=16'hffff;settle;
    if(shown!==16'hffff)$fatal(1,"full 16-bit counter was truncated");
    count_f=16'd0;settle;
    if(shown!==16'd0)$fatal(1,"zero count did not propagate");
    rst=1;@(negedge clk);
    if(shown!==16'd0)$fatal(1,"reset failed");
    rst=0;settle;
    if(shown!==count_f)$fatal(1,"reset recovery failed");
    $display("PASS shared diagnostic sampler: all pages, changing counts, rapid switching, FFFF, reset");
    $finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
