// 使用一个闲置DSP替代16位计数器进位链，结果仍按65536回绕。
// (65536+n)*65537 = 2^32+(n+1)*65536+n，取31:16即得到n+1的低16位。
module touch_counter_increment(
    input wire clk,input wire rst,input wire [15:0] count,output wire [15:0] next_count
);
wire [35:0] product;
EG_LOGIC_MULT #(.INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
    .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
    .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")) multiplier(
    .p(product),.a({2'b01,count}),.b(18'd65537),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
    .clk(clk),.rstan(!rst),.rstbn(!rst),.rstpdn(!rst));
assign next_count=product[31:16];
endmodule
