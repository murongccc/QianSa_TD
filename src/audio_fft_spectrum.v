// 512/256 点实数音频频谱。两组 RAM 轮流采样和蝶形计算；同一时刻
// 只有一个复数乘法器工作。输入为 48 kHz 的 24-bit 左声道 PCM。
module audio_fft_spectrum #(
    parameter integer FFT_POINTS = 512
)(
    input wire clk,
    input wire rst,
    input wire sample_valid,
    input wire [23:0] sample_pcm,
    input wire frame_start,
    output reg [255:0] bands
);
localparam integer ADDR_W = (FFT_POINTS == 512) ? 9 : 8;
localparam [ADDR_W-1:0] LAST_SAMPLE = FFT_POINTS - 1;
localparam [ADDR_W-1:0] LAST_BIN = FFT_POINTS / 2;
localparam [3:0] ST_IDLE=4'd0, ST_RD_A=4'd1, ST_LATCH_A=4'd2,
                 ST_RD_B=4'd3, ST_LATCH_B=4'd4, ST_M0=4'd5,
                 ST_M1=4'd6, ST_M2=4'd7, ST_M3=4'd8,
                 ST_CALC=4'd9, ST_WR_A=4'd10, ST_WR_B=4'd11,
                 ST_SCAN_RD=4'd12, ST_SCAN_EVAL=4'd13,
                 ST_BAND_COMMIT=4'd14;
reg [3:0] state;
reg capture_bank, process_bank;
reg [ADDR_W-1:0] sample_count;
reg [ADDR_W-1:0] group_base, pair_index, step;
reg [3:0] stage;
reg [ADDR_W-1:0] scan_bin;
reg [4:0] band_index;
reg [7:0] band_peak;
reg [13:0] band_sum;
reg [31:0] a_data, b_data, twiddle_word;
wire [31:0] read_data, bank0_q, bank1_q;
reg signed [31:0] p0, p1, p2, p3;
reg [31:0] result_a, result_b;
reg [255:0] bands_history, bands_build, bands_pending;
reg pending_valid, frame_start_d;
wire capture_we = sample_valid;
wire process_we = (state == ST_WR_A) || (state == ST_WR_B);
wire read_en = (state == ST_RD_A) || (state == ST_RD_B) ||
               (state == ST_SCAN_RD);
wire [ADDR_W-1:0] a_addr = group_base + pair_index;
wire [ADDR_W-1:0] b_addr = group_base + pair_index + step;
wire [ADDR_W-1:0] read_addr = (state == ST_RD_A) ? a_addr :
                                (state == ST_RD_B) ? b_addr : scan_bin;
wire [ADDR_W-1:0] write_addr = (state == ST_WR_A) ? a_addr : b_addr;
wire [31:0] write_data = (state == ST_WR_A) ? result_a : result_b;
wire [ADDR_W-1:0] capture_addr;
wire [8:0] window_phase = (FFT_POINTS == 512) ? sample_count :
                          {sample_count,1'b0};
wire [8:0] window_fold = (window_phase > 9'd256) ?
                         (9'd512 - window_phase) : window_phase;
wire [7:0] window_address = (window_fold > 9'd128) ?
                            (9'd256 - window_fold) : window_fold[7:0];
wire [7:0] window_quarter = hann_quarter(window_address[7:1]);
wire [8:0] window_gain = (window_fold > 9'd128) ?
                         (9'd256 - {1'b0,window_quarter}) :
                         {1'b0,window_quarter};
wire signed [15:0] pcm16 = sample_pcm[23:8];
wire signed [9:0] window_gain_signed = $signed({1'b0,window_gain});
wire signed [25:0] window_product = pcm16 * window_gain_signed;
wire signed [25:0] window_shifted = window_product >>> 8;
wire [15:0] windowed_pcm = window_shifted[15:0];
wire [7:0] twiddle_index = pair_index << (8-stage);
wire signed [15:0] mul_a = ((state == ST_M0) || (state == ST_M2)) ?
                           b_data[31:16] : b_data[15:0];
wire signed [15:0] mul_b = ((state == ST_M0) || (state == ST_M3)) ?
                           twiddle_word[31:16] : twiddle_word[15:0];
wire signed [31:0] product = mul_a * mul_b;
wire signed [32:0] real_product = $signed({p0[31],p0}) - $signed({p1[31],p1});
wire signed [32:0] imag_product = $signed({p2[31],p2}) + $signed({p3[31],p3});
wire signed [17:0] rotated_real = real_product >>> 15;
wire signed [17:0] rotated_imag = imag_product >>> 15;
wire signed [17:0] ar = $signed({{2{a_data[31]}},a_data[31:16]});
wire signed [17:0] ai = $signed({{2{a_data[15]}},a_data[15:0]});
wire [15:0] scan_real_abs = read_data[31] ? -read_data[31:16] : read_data[31:16];
wire [15:0] scan_imag_abs = read_data[15] ? -read_data[15:0] : read_data[15:0];
wire [16:0] scan_magnitude = {1'b0,scan_real_abs} + {1'b0,scan_imag_abs};
// 音乐的高频能量通常较低，分段补偿后用分段曲线提升弱信号的可见度。
// Hann 窗的相干增益约为 1/2，在显示映射前恢复约 6 dB。
wire [17:0] calibrated_magnitude = {scan_magnitude,1'b0};
wire [19:0] weighted_magnitude = (band_index >= 5'd24) ?
                                  {calibrated_magnitude,2'b00} :
                                  (band_index >= 5'd16) ?
                                  {1'b0,calibrated_magnitude,1'b0} :
                                  {2'b00,calibrated_magnitude};
wire [19:0] middle_level = 20'd128 +
                           ((weighted_magnitude - 20'd1024) >> 5);
wire [19:0] high_level = 20'd224 +
                         ((weighted_magnitude - 20'd4096) >> 7);
wire [7:0] scan_level = (scan_magnitude < 17'd32) ? 8'd0 :
                        (weighted_magnitude >= 20'd8192) ? 8'hff :
                        (weighted_magnitude < 20'd1024) ?
                        weighted_magnitude[10:3] :
                        (weighted_magnitude < 20'd4096) ?
                        middle_level[7:0] : high_level[7:0];
wire [7:0] next_peak = (scan_level > band_peak) ? scan_level : band_peak;
wire [13:0] next_sum = band_sum + {6'd0,scan_level};
wire [7:0] reciprocal = band_reciprocal(band_index);
wire [21:0] mean_product = band_sum * reciprocal;
wire [14:0] mean_scaled = (mean_product + 22'd64) >> 7;
wire [7:0] band_mean = (mean_scaled > 15'd255) ? 8'hff : mean_scaled[7:0];
// 峰值保持瞬态，均值抑制宽频段里单个 bin 的跳动。
wire [9:0] combined_sum = {2'b00,band_peak} +
                           {1'b0,band_peak,1'b0} +
                           {2'b00,band_mean} + 10'd2;
wire [7:0] band_level = combined_sum[9:2];
wire [7:0] old_band = bands_history[band_index*8 +: 8];
wire [7:0] rise_delta = band_level - old_band;
wire [7:0] fall_delta = old_band - band_level;
wire [9:0] rise_step = ({2'b00,rise_delta} + 10'd3) >> 2;
wire [10:0] fall_step = ({3'b000,fall_delta} + 11'd7) >> 3;
// 上升约四分之一差值、回落约八分之一；2 级死区过滤帧间小抖动。
wire [7:0] smoothed_band = (band_level > old_band) ?
                           ((rise_delta > 8'd2) ?
                            old_band + rise_step[7:0] : old_band) :
                           (((fall_delta > 8'd2) || (band_level == 8'd0)) ?
                            old_band - fall_step[7:0] : old_band);
wire bank0_we = (capture_we && !capture_bank) || (process_we && !process_bank);
wire bank1_we = (capture_we && capture_bank) || (process_we && process_bank);
wire [ADDR_W-1:0] bank0_addr = (process_we && !process_bank) ? write_addr : capture_addr;
wire [ADDR_W-1:0] bank1_addr = (process_we && process_bank) ? write_addr : capture_addr;
wire [31:0] bank0_data = (process_we && !process_bank) ? write_data :
                         {windowed_pcm,16'd0};
wire [31:0] bank1_data = (process_we && process_bank) ? write_data :
                         {windowed_pcm,16'd0};

// 输入按位反转地址写入，DIT 运算结束后频谱按自然序读出。
function [ADDR_W-1:0] bit_reverse;
    input [ADDR_W-1:0] value;
    integer n;
    begin
        for (n=0;n<ADDR_W;n=n+1)
            bit_reverse[n] = value[ADDR_W-1-n];
    end
endfunction
assign capture_addr = bit_reverse(sample_count);

function [15:0] sat16;
    input signed [17:0] value;
    begin
        if (value > 18'sd32767) sat16=16'h7fff;
        else if (value < -18'sd32768) sat16=16'h8000;
        else sat16=value[15:0];
    end
endfunction

function [8:0] band_last;
    input [4:0] index;
    begin
        if (FFT_POINTS == 512) begin
            case (index)
                5'd0: band_last = 9'd1;
                5'd1: band_last = 9'd2;
                5'd2: band_last = 9'd3;
                5'd3: band_last = 9'd4;
                5'd4: band_last = 9'd5;
                5'd5: band_last = 9'd6;
                5'd6: band_last = 9'd7;
                5'd7: band_last = 9'd8;
                5'd8: band_last = 9'd9;
                5'd9: band_last = 9'd10;
                5'd10: band_last = 9'd11;
                5'd11: band_last = 9'd12;
                5'd12: band_last = 9'd13;
                5'd13: band_last = 9'd14;
                5'd14: band_last = 9'd15;
                5'd15: band_last = 9'd16;
                5'd16: band_last = 9'd18;
                5'd17: band_last = 9'd22;
                5'd18: band_last = 9'd26;
                5'd19: band_last = 9'd31;
                5'd20: band_last = 9'd37;
                5'd21: band_last = 9'd44;
                5'd22: band_last = 9'd53;
                5'd23: band_last = 9'd63;
                5'd24: band_last = 9'd75;
                5'd25: band_last = 9'd90;
                5'd26: band_last = 9'd107;
                5'd27: band_last = 9'd127;
                5'd28: band_last = 9'd152;
                5'd29: band_last = 9'd181;
                5'd30: band_last = 9'd215;
                5'd31: band_last = 9'd256;
                default: band_last = 9'd256;
            endcase
        end else begin
            case (index)
                5'd0: band_last = 9'd1;
                5'd1: band_last = 9'd2;
                5'd2: band_last = 9'd3;
                5'd3: band_last = 9'd4;
                5'd4: band_last = 9'd5;
                5'd5: band_last = 9'd6;
                5'd6: band_last = 9'd7;
                5'd7: band_last = 9'd8;
                5'd8: band_last = 9'd9;
                5'd9: band_last = 9'd10;
                5'd10: band_last = 9'd11;
                5'd11: band_last = 9'd12;
                5'd12: band_last = 9'd13;
                5'd13: band_last = 9'd14;
                5'd14: band_last = 9'd15;
                5'd15: band_last = 9'd16;
                5'd16: band_last = 9'd17;
                5'd17: band_last = 9'd18;
                5'd18: band_last = 9'd19;
                5'd19: band_last = 9'd20;
                5'd20: band_last = 9'd23;
                5'd21: band_last = 9'd27;
                5'd22: band_last = 9'd32;
                5'd23: band_last = 9'd37;
                5'd24: band_last = 9'd44;
                5'd25: band_last = 9'd51;
                5'd26: band_last = 9'd59;
                5'd27: band_last = 9'd69;
                5'd28: band_last = 9'd81;
                5'd29: band_last = 9'd94;
                5'd30: band_last = 9'd110;
                5'd31: band_last = 9'd128;
                default: band_last = 9'd128;
            endcase
        end
    end
endfunction

// 周期 Hann 窗的四分之一周期表，每项跨两个采样，Q0.8 精度。
function [7:0] hann_quarter;
    input [6:0] index;
    begin
        case (index)
            7'd0: hann_quarter = 8'd0;
            7'd1: hann_quarter = 8'd0;
            7'd2: hann_quarter = 8'd0;
            7'd3: hann_quarter = 8'd0;
            7'd4: hann_quarter = 8'd1;
            7'd5: hann_quarter = 8'd1;
            7'd6: hann_quarter = 8'd1;
            7'd7: hann_quarter = 8'd2;
            7'd8: hann_quarter = 8'd2;
            7'd9: hann_quarter = 8'd3;
            7'd10: hann_quarter = 8'd4;
            7'd11: hann_quarter = 8'd5;
            7'd12: hann_quarter = 8'd6;
            7'd13: hann_quarter = 8'd6;
            7'd14: hann_quarter = 8'd7;
            7'd15: hann_quarter = 8'd9;
            7'd16: hann_quarter = 8'd10;
            7'd17: hann_quarter = 8'd11;
            7'd18: hann_quarter = 8'd12;
            7'd19: hann_quarter = 8'd14;
            7'd20: hann_quarter = 8'd15;
            7'd21: hann_quarter = 8'd17;
            7'd22: hann_quarter = 8'd18;
            7'd23: hann_quarter = 8'd20;
            7'd24: hann_quarter = 8'd22;
            7'd25: hann_quarter = 8'd23;
            7'd26: hann_quarter = 8'd25;
            7'd27: hann_quarter = 8'd27;
            7'd28: hann_quarter = 8'd29;
            7'd29: hann_quarter = 8'd31;
            7'd30: hann_quarter = 8'd33;
            7'd31: hann_quarter = 8'd35;
            7'd32: hann_quarter = 8'd37;
            7'd33: hann_quarter = 8'd40;
            7'd34: hann_quarter = 8'd42;
            7'd35: hann_quarter = 8'd44;
            7'd36: hann_quarter = 8'd47;
            7'd37: hann_quarter = 8'd49;
            7'd38: hann_quarter = 8'd52;
            7'd39: hann_quarter = 8'd54;
            7'd40: hann_quarter = 8'd57;
            7'd41: hann_quarter = 8'd60;
            7'd42: hann_quarter = 8'd62;
            7'd43: hann_quarter = 8'd65;
            7'd44: hann_quarter = 8'd68;
            7'd45: hann_quarter = 8'd70;
            7'd46: hann_quarter = 8'd73;
            7'd47: hann_quarter = 8'd76;
            7'd48: hann_quarter = 8'd79;
            7'd49: hann_quarter = 8'd82;
            7'd50: hann_quarter = 8'd85;
            7'd51: hann_quarter = 8'd88;
            7'd52: hann_quarter = 8'd91;
            7'd53: hann_quarter = 8'd94;
            7'd54: hann_quarter = 8'd97;
            7'd55: hann_quarter = 8'd100;
            7'd56: hann_quarter = 8'd103;
            7'd57: hann_quarter = 8'd106;
            7'd58: hann_quarter = 8'd109;
            7'd59: hann_quarter = 8'd112;
            7'd60: hann_quarter = 8'd115;
            7'd61: hann_quarter = 8'd119;
            7'd62: hann_quarter = 8'd122;
            7'd63: hann_quarter = 8'd125;
            7'd64: hann_quarter = 8'd128;
            default: hann_quarter = 8'd128;
        endcase
    end
endfunction

// 每段 bin 数的 Q0.7 倒数，均值误差只占混合幅度的四分之一。
function [7:0] band_reciprocal;
    input [4:0] index;
    begin
        band_reciprocal = 8'd128;
        if (FFT_POINTS == 512) begin
            case (index)
                5'd16: band_reciprocal = 8'd64;
                5'd17: band_reciprocal = 8'd32;
                5'd18: band_reciprocal = 8'd32;
                5'd19: band_reciprocal = 8'd26;
                5'd20: band_reciprocal = 8'd21;
                5'd21: band_reciprocal = 8'd18;
                5'd22: band_reciprocal = 8'd14;
                5'd23: band_reciprocal = 8'd13;
                5'd24: band_reciprocal = 8'd11;
                5'd25: band_reciprocal = 8'd9;
                5'd26: band_reciprocal = 8'd8;
                5'd27: band_reciprocal = 8'd6;
                5'd28: band_reciprocal = 8'd5;
                5'd29: band_reciprocal = 8'd4;
                5'd30: band_reciprocal = 8'd4;
                5'd31: band_reciprocal = 8'd3;
                default: band_reciprocal = 8'd128;
            endcase
        end else begin
            case (index)
                5'd16: band_reciprocal = 8'd128;
                5'd17: band_reciprocal = 8'd128;
                5'd18: band_reciprocal = 8'd128;
                5'd19: band_reciprocal = 8'd128;
                5'd20: band_reciprocal = 8'd43;
                5'd21: band_reciprocal = 8'd32;
                5'd22: band_reciprocal = 8'd26;
                5'd23: band_reciprocal = 8'd26;
                5'd24: band_reciprocal = 8'd18;
                5'd25: band_reciprocal = 8'd18;
                5'd26: band_reciprocal = 8'd16;
                5'd27: band_reciprocal = 8'd13;
                5'd28: band_reciprocal = 8'd11;
                5'd29: band_reciprocal = 8'd10;
                5'd30: band_reciprocal = 8'd8;
                5'd31: band_reciprocal = 8'd7;
                default: band_reciprocal = 8'd128;
            endcase
        end
    end
endfunction


// Q1.15 的 e^(-j2πk/512)。256 点模式使用偶数地址。
function [31:0] twiddle;
    input [7:0] index;
    begin
        case (index)
            8'd0: twiddle = 32'h7fff0000;
            8'd1: twiddle = 32'h7ffdfe6e;
            8'd2: twiddle = 32'h7ff5fcdc;
            8'd3: twiddle = 32'h7fe9fb4a;
            8'd4: twiddle = 32'h7fd8f9b8;
            8'd5: twiddle = 32'h7fc1f827;
            8'd6: twiddle = 32'h7fa6f696;
            8'd7: twiddle = 32'h7f86f505;
            8'd8: twiddle = 32'h7f61f374;
            8'd9: twiddle = 32'h7f37f1e4;
            8'd10: twiddle = 32'h7f09f055;
            8'd11: twiddle = 32'h7ed5eec6;
            8'd12: twiddle = 32'h7e9ced38;
            8'd13: twiddle = 32'h7e5febab;
            8'd14: twiddle = 32'h7e1dea1e;
            8'd15: twiddle = 32'h7dd5e892;
            8'd16: twiddle = 32'h7d89e707;
            8'd17: twiddle = 32'h7d39e57e;
            8'd18: twiddle = 32'h7ce3e3f5;
            8'd19: twiddle = 32'h7c88e26d;
            8'd20: twiddle = 32'h7c29e0e6;
            8'd21: twiddle = 32'h7bc5df61;
            8'd22: twiddle = 32'h7b5cdddd;
            8'd23: twiddle = 32'h7aeedc5a;
            8'd24: twiddle = 32'h7a7cdad8;
            8'd25: twiddle = 32'h7a05d958;
            8'd26: twiddle = 32'h7989d7da;
            8'd27: twiddle = 32'h7909d65d;
            8'd28: twiddle = 32'h7884d4e1;
            8'd29: twiddle = 32'h77fad367;
            8'd30: twiddle = 32'h776bd1ef;
            8'd31: twiddle = 32'h76d8d079;
            8'd32: twiddle = 32'h7641cf05;
            8'd33: twiddle = 32'h75a5cd92;
            8'd34: twiddle = 32'h7504cc21;
            8'd35: twiddle = 32'h745fcab3;
            8'd36: twiddle = 32'h73b5c946;
            8'd37: twiddle = 32'h7307c7dc;
            8'd38: twiddle = 32'h7254c674;
            8'd39: twiddle = 32'h719dc50e;
            8'd40: twiddle = 32'h70e2c3aa;
            8'd41: twiddle = 32'h7022c248;
            8'd42: twiddle = 32'h6f5ec0e9;
            8'd43: twiddle = 32'h6e96bf8d;
            8'd44: twiddle = 32'h6dc9be32;
            8'd45: twiddle = 32'h6cf8bcdb;
            8'd46: twiddle = 32'h6c23bb86;
            8'd47: twiddle = 32'h6b4aba33;
            8'd48: twiddle = 32'h6a6db8e4;
            8'd49: twiddle = 32'h698bb797;
            8'd50: twiddle = 32'h68a6b64c;
            8'd51: twiddle = 32'h67bcb505;
            8'd52: twiddle = 32'h66cfb3c1;
            8'd53: twiddle = 32'h65ddb27f;
            8'd54: twiddle = 32'h64e8b141;
            8'd55: twiddle = 32'h63eeb005;
            8'd56: twiddle = 32'h62f1aecd;
            8'd57: twiddle = 32'h61f0ad98;
            8'd58: twiddle = 32'h60ebac65;
            8'd59: twiddle = 32'h5fe3ab37;
            8'd60: twiddle = 32'h5ed7aa0b;
            8'd61: twiddle = 32'h5dc7a8e3;
            8'd62: twiddle = 32'h5cb3a7be;
            8'd63: twiddle = 32'h5b9ca69c;
            8'd64: twiddle = 32'h5a82a57e;
            8'd65: twiddle = 32'h5964a464;
            8'd66: twiddle = 32'h5842a34d;
            8'd67: twiddle = 32'h571da239;
            8'd68: twiddle = 32'h55f5a129;
            8'd69: twiddle = 32'h54c9a01d;
            8'd70: twiddle = 32'h539b9f15;
            8'd71: twiddle = 32'h52689e10;
            8'd72: twiddle = 32'h51339d0f;
            8'd73: twiddle = 32'h4ffb9c12;
            8'd74: twiddle = 32'h4ebf9b18;
            8'd75: twiddle = 32'h4d819a23;
            8'd76: twiddle = 32'h4c3f9931;
            8'd77: twiddle = 32'h4afb9844;
            8'd78: twiddle = 32'h49b4975a;
            8'd79: twiddle = 32'h48699675;
            8'd80: twiddle = 32'h471c9593;
            8'd81: twiddle = 32'h45cd94b6;
            8'd82: twiddle = 32'h447a93dd;
            8'd83: twiddle = 32'h43259308;
            8'd84: twiddle = 32'h41ce9237;
            8'd85: twiddle = 32'h4073916a;
            8'd86: twiddle = 32'h3f1790a2;
            8'd87: twiddle = 32'h3db88fde;
            8'd88: twiddle = 32'h3c568f1e;
            8'd89: twiddle = 32'h3af28e63;
            8'd90: twiddle = 32'h398c8dac;
            8'd91: twiddle = 32'h38248cf9;
            8'd92: twiddle = 32'h36ba8c4b;
            8'd93: twiddle = 32'h354d8ba1;
            8'd94: twiddle = 32'h33df8afc;
            8'd95: twiddle = 32'h326e8a5b;
            8'd96: twiddle = 32'h30fb89bf;
            8'd97: twiddle = 32'h2f878928;
            8'd98: twiddle = 32'h2e118895;
            8'd99: twiddle = 32'h2c998806;
            8'd100: twiddle = 32'h2b1f877c;
            8'd101: twiddle = 32'h29a386f7;
            8'd102: twiddle = 32'h28268677;
            8'd103: twiddle = 32'h26a885fb;
            8'd104: twiddle = 32'h25288584;
            8'd105: twiddle = 32'h23a68512;
            8'd106: twiddle = 32'h222384a4;
            8'd107: twiddle = 32'h209f843b;
            8'd108: twiddle = 32'h1f1a83d7;
            8'd109: twiddle = 32'h1d938378;
            8'd110: twiddle = 32'h1c0b831d;
            8'd111: twiddle = 32'h1a8282c7;
            8'd112: twiddle = 32'h18f98277;
            8'd113: twiddle = 32'h176e822b;
            8'd114: twiddle = 32'h15e281e3;
            8'd115: twiddle = 32'h145581a1;
            8'd116: twiddle = 32'h12c88164;
            8'd117: twiddle = 32'h113a812b;
            8'd118: twiddle = 32'h0fab80f7;
            8'd119: twiddle = 32'h0e1c80c9;
            8'd120: twiddle = 32'h0c8c809f;
            8'd121: twiddle = 32'h0afb807a;
            8'd122: twiddle = 32'h096a805a;
            8'd123: twiddle = 32'h07d9803f;
            8'd124: twiddle = 32'h06488028;
            8'd125: twiddle = 32'h04b68017;
            8'd126: twiddle = 32'h0324800b;
            8'd127: twiddle = 32'h01928003;
            8'd128: twiddle = 32'h00008001;
            8'd129: twiddle = 32'hfe6e8003;
            8'd130: twiddle = 32'hfcdc800b;
            8'd131: twiddle = 32'hfb4a8017;
            8'd132: twiddle = 32'hf9b88028;
            8'd133: twiddle = 32'hf827803f;
            8'd134: twiddle = 32'hf696805a;
            8'd135: twiddle = 32'hf505807a;
            8'd136: twiddle = 32'hf374809f;
            8'd137: twiddle = 32'hf1e480c9;
            8'd138: twiddle = 32'hf05580f7;
            8'd139: twiddle = 32'heec6812b;
            8'd140: twiddle = 32'hed388164;
            8'd141: twiddle = 32'hebab81a1;
            8'd142: twiddle = 32'hea1e81e3;
            8'd143: twiddle = 32'he892822b;
            8'd144: twiddle = 32'he7078277;
            8'd145: twiddle = 32'he57e82c7;
            8'd146: twiddle = 32'he3f5831d;
            8'd147: twiddle = 32'he26d8378;
            8'd148: twiddle = 32'he0e683d7;
            8'd149: twiddle = 32'hdf61843b;
            8'd150: twiddle = 32'hdddd84a4;
            8'd151: twiddle = 32'hdc5a8512;
            8'd152: twiddle = 32'hdad88584;
            8'd153: twiddle = 32'hd95885fb;
            8'd154: twiddle = 32'hd7da8677;
            8'd155: twiddle = 32'hd65d86f7;
            8'd156: twiddle = 32'hd4e1877c;
            8'd157: twiddle = 32'hd3678806;
            8'd158: twiddle = 32'hd1ef8895;
            8'd159: twiddle = 32'hd0798928;
            8'd160: twiddle = 32'hcf0589bf;
            8'd161: twiddle = 32'hcd928a5b;
            8'd162: twiddle = 32'hcc218afc;
            8'd163: twiddle = 32'hcab38ba1;
            8'd164: twiddle = 32'hc9468c4b;
            8'd165: twiddle = 32'hc7dc8cf9;
            8'd166: twiddle = 32'hc6748dac;
            8'd167: twiddle = 32'hc50e8e63;
            8'd168: twiddle = 32'hc3aa8f1e;
            8'd169: twiddle = 32'hc2488fde;
            8'd170: twiddle = 32'hc0e990a2;
            8'd171: twiddle = 32'hbf8d916a;
            8'd172: twiddle = 32'hbe329237;
            8'd173: twiddle = 32'hbcdb9308;
            8'd174: twiddle = 32'hbb8693dd;
            8'd175: twiddle = 32'hba3394b6;
            8'd176: twiddle = 32'hb8e49593;
            8'd177: twiddle = 32'hb7979675;
            8'd178: twiddle = 32'hb64c975a;
            8'd179: twiddle = 32'hb5059844;
            8'd180: twiddle = 32'hb3c19931;
            8'd181: twiddle = 32'hb27f9a23;
            8'd182: twiddle = 32'hb1419b18;
            8'd183: twiddle = 32'hb0059c12;
            8'd184: twiddle = 32'haecd9d0f;
            8'd185: twiddle = 32'had989e10;
            8'd186: twiddle = 32'hac659f15;
            8'd187: twiddle = 32'hab37a01d;
            8'd188: twiddle = 32'haa0ba129;
            8'd189: twiddle = 32'ha8e3a239;
            8'd190: twiddle = 32'ha7bea34d;
            8'd191: twiddle = 32'ha69ca464;
            8'd192: twiddle = 32'ha57ea57e;
            8'd193: twiddle = 32'ha464a69c;
            8'd194: twiddle = 32'ha34da7be;
            8'd195: twiddle = 32'ha239a8e3;
            8'd196: twiddle = 32'ha129aa0b;
            8'd197: twiddle = 32'ha01dab37;
            8'd198: twiddle = 32'h9f15ac65;
            8'd199: twiddle = 32'h9e10ad98;
            8'd200: twiddle = 32'h9d0faecd;
            8'd201: twiddle = 32'h9c12b005;
            8'd202: twiddle = 32'h9b18b141;
            8'd203: twiddle = 32'h9a23b27f;
            8'd204: twiddle = 32'h9931b3c1;
            8'd205: twiddle = 32'h9844b505;
            8'd206: twiddle = 32'h975ab64c;
            8'd207: twiddle = 32'h9675b797;
            8'd208: twiddle = 32'h9593b8e4;
            8'd209: twiddle = 32'h94b6ba33;
            8'd210: twiddle = 32'h93ddbb86;
            8'd211: twiddle = 32'h9308bcdb;
            8'd212: twiddle = 32'h9237be32;
            8'd213: twiddle = 32'h916abf8d;
            8'd214: twiddle = 32'h90a2c0e9;
            8'd215: twiddle = 32'h8fdec248;
            8'd216: twiddle = 32'h8f1ec3aa;
            8'd217: twiddle = 32'h8e63c50e;
            8'd218: twiddle = 32'h8dacc674;
            8'd219: twiddle = 32'h8cf9c7dc;
            8'd220: twiddle = 32'h8c4bc946;
            8'd221: twiddle = 32'h8ba1cab3;
            8'd222: twiddle = 32'h8afccc21;
            8'd223: twiddle = 32'h8a5bcd92;
            8'd224: twiddle = 32'h89bfcf05;
            8'd225: twiddle = 32'h8928d079;
            8'd226: twiddle = 32'h8895d1ef;
            8'd227: twiddle = 32'h8806d367;
            8'd228: twiddle = 32'h877cd4e1;
            8'd229: twiddle = 32'h86f7d65d;
            8'd230: twiddle = 32'h8677d7da;
            8'd231: twiddle = 32'h85fbd958;
            8'd232: twiddle = 32'h8584dad8;
            8'd233: twiddle = 32'h8512dc5a;
            8'd234: twiddle = 32'h84a4dddd;
            8'd235: twiddle = 32'h843bdf61;
            8'd236: twiddle = 32'h83d7e0e6;
            8'd237: twiddle = 32'h8378e26d;
            8'd238: twiddle = 32'h831de3f5;
            8'd239: twiddle = 32'h82c7e57e;
            8'd240: twiddle = 32'h8277e707;
            8'd241: twiddle = 32'h822be892;
            8'd242: twiddle = 32'h81e3ea1e;
            8'd243: twiddle = 32'h81a1ebab;
            8'd244: twiddle = 32'h8164ed38;
            8'd245: twiddle = 32'h812beec6;
            8'd246: twiddle = 32'h80f7f055;
            8'd247: twiddle = 32'h80c9f1e4;
            8'd248: twiddle = 32'h809ff374;
            8'd249: twiddle = 32'h807af505;
            8'd250: twiddle = 32'h805af696;
            8'd251: twiddle = 32'h803ff827;
            8'd252: twiddle = 32'h8028f9b8;
            8'd253: twiddle = 32'h8017fb4a;
            8'd254: twiddle = 32'h800bfcdc;
            8'd255: twiddle = 32'h8003fe6e;
            default: twiddle = 32'h7fff0000;
        endcase
    end
endfunction

// 每个 bank 是单写口、同步读口；采样与蝶形访问不同 bank。
fft_spectrum_bank_ram #(.DEPTH(FFT_POINTS), .ADDR_W(ADDR_W)) u_bank0 (
    .clk(clk), .we(bank0_we), .write_addr(bank0_addr), .write_data(bank0_data),
    .re(read_en && !process_bank), .read_addr(read_addr), .read_data(bank0_q)
);
fft_spectrum_bank_ram #(.DEPTH(FFT_POINTS), .ADDR_W(ADDR_W)) u_bank1 (
    .clk(clk), .we(bank1_we), .write_addr(bank1_addr), .write_data(bank1_data),
    .re(read_en && process_bank), .read_addr(read_addr), .read_data(bank1_q)
);
assign read_data = process_bank ? bank1_q : bank0_q;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=ST_IDLE; capture_bank<=1'b0; process_bank<=1'b0;
        sample_count<={ADDR_W{1'b0}}; group_base<={ADDR_W{1'b0}};
        pair_index<={ADDR_W{1'b0}}; step<=1; stage<=0;
        scan_bin<=1; band_index<=0; band_peak<=0; band_sum<=0;
        a_data<=0; b_data<=0; twiddle_word<=0;
        p0<=0; p1<=0; p2<=0; p3<=0; result_a<=0; result_b<=0;
        bands<=0; bands_history<=0; bands_build<=0; bands_pending<=0;
        pending_valid<=1'b0; frame_start_d<=1'b0;
    end else begin
        frame_start_d <= frame_start;
        if (frame_start && !frame_start_d && pending_valid) begin
            bands <= bands_pending;
            pending_valid <= 1'b0;
        end
        if (sample_valid) begin
            if (sample_count == LAST_SAMPLE) begin
                sample_count <= 0;
                if (state == ST_IDLE) begin
                    process_bank <= capture_bank;
                    capture_bank <= ~capture_bank;
                    group_base <= 0; pair_index <= 0; step <= 1;
                    stage <= 0; state <= ST_RD_A;
                end
            end else sample_count <= sample_count + 1'b1;
        end
        case (state)
            ST_IDLE: begin end
            ST_RD_A: state <= ST_LATCH_A;
            ST_LATCH_A: begin a_data <= read_data; state <= ST_RD_B; end
            ST_RD_B: state <= ST_LATCH_B;
            ST_LATCH_B: begin
                b_data <= read_data;
                twiddle_word <= twiddle(twiddle_index);
                state <= ST_M0;
            end
            ST_M0: begin p0 <= product; state <= ST_M1; end
            ST_M1: begin p1 <= product; state <= ST_M2; end
            ST_M2: begin p2 <= product; state <= ST_M3; end
            ST_M3: begin p3 <= product; state <= ST_CALC; end
            ST_CALC: begin
                result_a <= {sat16((ar + rotated_real) >>> 1),
                             sat16((ai + rotated_imag) >>> 1)};
                result_b <= {sat16((ar - rotated_real) >>> 1),
                             sat16((ai - rotated_imag) >>> 1)};
                state <= ST_WR_A;
            end
            ST_WR_A: state <= ST_WR_B;
            ST_WR_B: begin
                if (pair_index + 1'b1 < step)
                    pair_index <= pair_index + 1'b1;
                else begin
                    pair_index <= 0;
                    if ({1'b0,group_base} + {step,1'b0} < FFT_POINTS)
                        group_base <= group_base + (step << 1);
                    else begin
                        group_base <= 0;
                        step <= step << 1;
                        stage <= stage + 1'b1;
                        if (stage == ADDR_W-1) begin
                            scan_bin <= 1; band_index <= 0;
                            band_peak <= 0; band_sum <= 0;
                            state <= ST_SCAN_RD;
                        end
                    end
                end
                if (stage != ADDR_W-1 ||
                    (pair_index + 1'b1 < step) ||
                    ({1'b0,group_base} + {step,1'b0} < FFT_POINTS))
                    state <= ST_RD_A;
            end
            ST_SCAN_RD: state <= ST_SCAN_EVAL;
            ST_SCAN_EVAL: begin
                band_peak <= next_peak;
                band_sum <= next_sum;
                if (scan_bin != LAST_BIN) scan_bin <= scan_bin + 1'b1;
                if ({1'b0,scan_bin} == band_last(band_index))
                    state <= ST_BAND_COMMIT;
                else state <= ST_SCAN_RD;
            end
            ST_BAND_COMMIT: begin
                bands_history[band_index*8 +: 8] <= smoothed_band;
                bands_build[band_index*8 +: 8] <= smoothed_band;
                band_index <= band_index + 1'b1;
                band_peak <= 0;
                band_sum <= 0;
                if (band_index == 5'd31) begin
                    bands_pending <= {smoothed_band,bands_build[247:0]};
                    pending_valid <= 1'b1;
                    state <= ST_IDLE;
                end else state <= ST_SCAN_RD;
            end
            default: state <= ST_IDLE;
        endcase
    end
end
endmodule

module fft_spectrum_bank_ram #(
    parameter integer DEPTH=512,
    parameter integer ADDR_W=9
)(
    input wire clk,
    input wire we,
    input wire [ADDR_W-1:0] write_addr,
    input wire [31:0] write_data,
    input wire re,
    input wire [ADDR_W-1:0] read_addr,
    output reg [31:0] read_data
);
(* ram_style = "bram" *) reg [31:0] memory [0:DEPTH-1];
always @(posedge clk) begin
    if (we) memory[write_addr] <= write_data;
    if (re) read_data <= memory[read_addr];
end
endmodule
