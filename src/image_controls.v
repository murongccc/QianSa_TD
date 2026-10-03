// 板载图像参数控制。KEY 为低有效按键，SW 为电平选择开关。
module image_controls #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer DEBOUNCE_MS = 20, parameter integer ENABLE_GAME_GUARD = 0
)(
    input  wire clk, input wire rst,
    input  wire key_inc_n, input wire key_dec_n,
    input wire freeze, input  wire sw_sel_b, input wire sw_sel_a,
    output reg [6:0] brightness, output reg [6:0] contrast,
    output reg [6:0] sharpness, output reg [1:0] selected,
    output reg select_toggle, output reg adjust_toggle
);
wire inc_pulse, dec_pulse;
reg controls_armed;
reg [1:0] released_meta,released_sync;
wire frozen=ENABLE_GAME_GUARD && freeze;
reg swb0, swb1, swa0, swa1;
reg [1:0] sw_prev;
media_key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS))
u_inc(.clk(clk),.rst(rst),.button_n(key_inc_n),.press_pulse(inc_pulse));
media_key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS))
u_dec(.clk(clk),.rst(rst),.button_n(key_dec_n),.press_pulse(dec_pulse));

always @(posedge clk or posedge rst) begin
    if (rst) begin
        controls_armed<=1;released_meta<=2'b11;released_sync<=2'b11;
        swb0<=0; swb1<=0; swa0<=0; swa1<=0; sw_prev<=2'b00;
        brightness<=7'd50; contrast<=7'd50; sharpness<=7'd50;
        selected<=2'b00; select_toggle<=0; adjust_toggle<=0;
    end else begin
        released_meta<={key_inc_n,key_dec_n};released_sync<=released_meta;
        if(frozen)controls_armed<=0;else if(&released_sync)controls_armed<=1;
        swb0<=sw_sel_b; swb1<=swb0; swa0<=sw_sel_a; swa1<=swa0;
        if ({swb1,swa1} != sw_prev) begin
            sw_prev <= {swb1,swa1};
            // 10/11 为保留组合，不改变当前选择，也不弹出 OSD。
            if (!swb1) begin
                selected <= {swb1,swa1};
                select_toggle <= ~select_toggle;
            end
        end
        if ((inc_pulse || dec_pulse) && !frozen && controls_armed) begin
            adjust_toggle <= ~adjust_toggle;
            case (selected)
                2'd0: if (inc_pulse && brightness<100) brightness<=brightness+7'd5;
                      else if (dec_pulse && brightness>0) brightness<=brightness-7'd5;
                2'd1: if (inc_pulse && contrast<100) contrast<=contrast+7'd5;
                      else if (dec_pulse && contrast>0) contrast<=contrast-7'd5;
                default: ;
            endcase
        end
    end
end
endmodule
