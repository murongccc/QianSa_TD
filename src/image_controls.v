// Board controls for image parameters.  KEY inputs are active low; SW inputs
// are level inputs from the four-position selector bank.
module image_controls #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk, input wire rst,
    input  wire key_inc_n, input wire key_dec_n,
    input  wire sw_sel_b, input wire sw_sel_a,
    output reg [6:0] brightness, output reg [6:0] contrast,
    output reg [6:0] sharpness, output reg [1:0] selected,
    output reg select_toggle, output reg adjust_toggle,
    output reg adjust_inc
);
wire inc_pulse, dec_pulse;
reg swb0, swb1, swa0, swa1;
reg [1:0] sw_prev;
media_key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS))
u_inc(.clk(clk),.rst(rst),.button_n(key_inc_n),.press_pulse(inc_pulse));
media_key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS))
u_dec(.clk(clk),.rst(rst),.button_n(key_dec_n),.press_pulse(dec_pulse));

always @(posedge clk or posedge rst) begin
    if (rst) begin
        swb0<=0; swb1<=0; swa0<=0; swa1<=0; sw_prev<=2'b00;
        brightness<=7'd50; contrast<=7'd50; sharpness<=7'd50;
        selected<=2'b00; select_toggle<=0; adjust_toggle<=0; adjust_inc<=0;
    end else begin
        swb0<=sw_sel_b; swb1<=swb0; swa0<=sw_sel_a; swa1<=swa0;
        if ({swb1,swa1} != sw_prev) begin
            sw_prev <= {swb1,swa1};
            if ({swb1,swa1} != 2'b11) begin
                selected <= {swb1,swa1};
                select_toggle <= ~select_toggle;
            end
        end
        if (inc_pulse || dec_pulse) begin
            adjust_toggle <= ~adjust_toggle;
            adjust_inc <= inc_pulse;
            case (selected)
                2'd0: if (inc_pulse && brightness<100) brightness<=brightness+7'd5;
                      else if (dec_pulse && brightness>0) brightness<=brightness-7'd5;
                2'd1: if (inc_pulse && contrast<100) contrast<=contrast+7'd5;
                      else if (dec_pulse && contrast>0) contrast<=contrast-7'd5;
                2'd2: if (inc_pulse && sharpness<100) sharpness<=sharpness+7'd5;
                      else if (dec_pulse && sharpness>0) sharpness<=sharpness-7'd5;
                default: ;
            endcase
        end
    end
end
endmodule
