`timescale 1ns/1ps

// 仅供 RTL 仿真使用。综合工程继续使用器件提供的 EG_LOGIC_MULT 原语。
module EG_LOGIC_MULT #(
    parameter INPUT_WIDTH_A = 18,
    parameter INPUT_WIDTH_B = 18,
    parameter OUTPUT_WIDTH = 36,
    parameter INPUTFORMAT = "UNSIGNED",
    parameter INPUTREGA = "DISABLE",
    parameter INPUTREGB = "DISABLE",
    parameter OUTPUTREG = "DISABLE",
    parameter IMPLEMENT = "DSP",
    parameter SRMODE = "ASYNC"
) (
    output wire [OUTPUT_WIDTH-1:0] p,
    input wire [INPUT_WIDTH_A-1:0] a,
    input wire [INPUT_WIDTH_B-1:0] b,
    input wire cea, ceb, cepd, clk, rstan, rstbn, rstpdn
);
assign p = a * b;
endmodule
