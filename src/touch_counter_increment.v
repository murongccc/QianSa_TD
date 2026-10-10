// 精确16位递增，按65536回绕；由调用者共享互斥事件的递增器。
module touch_counter_increment #(parameter integer USE_DSP=0)(
    input wire clk,input wire rst,input wire [15:0] count,output wire [15:0] next_count
);
generate if(USE_DSP)begin : g_dsp_counter
    // 独立计数器可让TD把反馈状态吸入DSP，缓解高密度设计的MSlice压力。
    wire [35:0] product;
    EG_LOGIC_MULT #(.INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
        .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
        .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")) multiplier(
        .p(product),.a({2'b01,count}),.b(18'd65537),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
        .clk(clk),.rstan(!rst),.rstbn(!rst),.rstpdn(!rst));
    assign next_count=product[31:16];
end else begin : g_logic_counter
    // 互斥报告统计共用的组合递增，不增加更新延迟。
    assign next_count=count+16'd1;
end endgenerate
endmodule
