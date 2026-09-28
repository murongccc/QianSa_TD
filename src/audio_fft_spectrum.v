// 兼容旧频段接口；板级参考模式直接输出 80 柱，不经过 32 段汇总。
module audio_fft_spectrum #(
    parameter integer FFT_POINTS=512,
    parameter integer REFERENCE_MODE=0
)(
    input wire clk, input wire rst, input wire sample_valid,
    input wire [23:0] sample_pcm, input wire frame_start,
    output wire [255:0] bands, output wire [639:0] bars,
    output wire [7:0] breath_radius
);
generate
    if (REFERENCE_MODE) begin: g_reference
        reference_fft_spectrum #(.FFT_POINTS(FFT_POINTS)) u_reference (
            .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),
            .frame_start(frame_start),.bars(bars),.breath_radius(breath_radius));
        assign bands=256'd0;
    end else begin: g_legacy
        legacy_audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS)) u_legacy (
            .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),
            .frame_start(frame_start),.bands(bands));
        assign bars=640'd0;
        assign breath_radius=8'd90;
    end
endgenerate
endmodule

// 512/256 点实数音频频谱。两组 RAM 轮流采样和蝶形计算；同一时刻
// 只有一个复数乘法器工作。输入为 48 kHz 的 24-bit 左声道 PCM。
module legacy_audio_fft_spectrum #(
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
localparam [ADDR_W-1:0] LAST_BIN = (FFT_POINTS == 512) ? 75 : 85;
localparam [4:0] ST_IDLE=5'd0, ST_RD_A=5'd1, ST_LATCH_A=5'd2,
                 ST_RD_B=5'd3, ST_LATCH_B=5'd4, ST_M0=5'd5,
                 ST_M1=5'd6, ST_M2=5'd7, ST_M3=5'd8,
                 ST_CALC=5'd9, ST_WR_A=5'd10, ST_WR_B=5'd11,
                 ST_SCAN_RD=5'd12, ST_SCAN_EVAL=5'd13,
                 ST_BAND_COMMIT=5'd14, ST_BAND_MIX=5'd15,
                 ST_BAND_GAIN=5'd16, ST_BAND_LEVEL=5'd17,
                 ST_BAND_PUBLISH=5'd18;
reg [4:0] state;
reg capture_bank, process_bank;
reg [ADDR_W-1:0] sample_count;
reg [ADDR_W-1:0] group_base, pair_index, step;
reg [3:0] stage;
reg [ADDR_W-1:0] scan_bin;
reg [4:0] band_index;
// 原始 L1 幅度最多 65536；两种配置的累加均保留保护位。
reg [16:0] band_peak;
reg [21:0] band_sum;
// 以下仅为分拍中间值，进入发布状态前全部被覆盖，无需异步复位。
// 避免给全局复位网络增加 DSP/数据寄存器的保持修复负载。
reg [29:0] mean_product;
reg [16:0] mixed_magnitude;
reg [26:0] gain_product;
reg [7:0] band_level;
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
// 在线性幅度域汇总，避免逐 bin 封顶后丢失高潮的幅度变化。
wire [16:0] next_peak = (scan_magnitude > band_peak) ? scan_magnitude : band_peak;
wire [21:0] next_sum = band_sum + {5'd0,scan_magnitude};
wire [7:0] reciprocal = band_reciprocal(band_index);
wire [29:0] rounded_mean = mean_product + 30'd64;
wire [16:0] band_mean = rounded_mean[23:7];
wire [18:0] combined_sum = {2'b00,band_peak} +
                           {1'b0,band_peak,1'b0} +
                           {2'b00,band_mean} + 19'd2;
// Q1.8 补偿从 1.0 连续增加到 1.96875，避免原来的 2/4 倍台阶。
wire [8:0] band_gain = 9'd256 + {1'b0,band_index,3'b000};
wire [18:0] display_magnitude = gain_product[26:8];
wire [7:0] old_band = bands_history[band_index*8 +: 8];
wire [7:0] rise_delta = band_level - old_band;
wire [7:0] fall_delta = old_band - band_level;
wire [8:0] rise_step = ({1'b0,rise_delta} + 9'd1) >> 1;
wire [10:0] fall_step = ({3'b000,fall_delta} + 11'd7) >> 3;
// 快升慢落，向上取整保证小差值仍收敛，静音最终严格归零。
wire [7:0] smoothed_band = (band_level > old_band) ?
                           old_band + rise_step[7:0] :
                           old_band - fall_step[7:0];
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

// 512 点视觉模式独立分析 bin1，末端 bin75 = 7031.25 Hz。
// 256 点保留旧频段作为兼容模式；板级使用 512 点。
function [8:0] band_last;
    input [4:0] index;
    reg [7:0] last_256;
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
                5'd16: band_last = 9'd17;
                5'd17: band_last = 9'd19;
                5'd18: band_last = 9'd21;
                5'd19: band_last = 9'd24;
                5'd20: band_last = 9'd27;
                5'd21: band_last = 9'd30;
                5'd22: band_last = 9'd34;
                5'd23: band_last = 9'd38;
                5'd24: band_last = 9'd43;
                5'd25: band_last = 9'd48;
                5'd26: band_last = 9'd54;
                5'd27: band_last = 9'd60;
                5'd28: band_last = 9'd66;
                5'd29: band_last = 9'd70;
                5'd30: band_last = 9'd73;
                5'd31: band_last = 9'd75;
                default: band_last = 9'd75;
            endcase
        end else begin
            case (index)
                5'd0: last_256 = 8'd1;
                5'd1: last_256 = 8'd2;
                5'd2: last_256 = 8'd3;
                5'd3: last_256 = 8'd4;
                5'd4: last_256 = 8'd5;
                5'd5: last_256 = 8'd6;
                5'd6: last_256 = 8'd7;
                5'd7: last_256 = 8'd8;
                5'd8: last_256 = 8'd9;
                5'd9: last_256 = 8'd10;
                5'd10: last_256 = 8'd11;
                5'd11: last_256 = 8'd12;
                5'd12: last_256 = 8'd13;
                5'd13: last_256 = 8'd14;
                5'd14: last_256 = 8'd15;
                5'd15: last_256 = 8'd16;
                5'd16: last_256 = 8'd17;
                5'd17: last_256 = 8'd18;
                5'd18: last_256 = 8'd19;
                5'd19: last_256 = 8'd20;
                5'd20: last_256 = 8'd22;
                5'd21: last_256 = 8'd25;
                5'd22: last_256 = 8'd28;
                5'd23: last_256 = 8'd32;
                5'd24: last_256 = 8'd36;
                5'd25: last_256 = 8'd41;
                5'd26: last_256 = 8'd47;
                5'd27: last_256 = 8'd53;
                5'd28: last_256 = 8'd60;
                5'd29: last_256 = 8'd67;
                5'd30: last_256 = 8'd76;
                5'd31: last_256 = 8'd85;
                default: last_256 = 8'd85;
            endcase
            band_last = {1'b0,last_256};
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
        if (FFT_POINTS == 512) begin
            case (index)
                5'd0: band_reciprocal = 8'd128;
                5'd1: band_reciprocal = 8'd128;
                5'd2: band_reciprocal = 8'd128;
                5'd3: band_reciprocal = 8'd128;
                5'd4: band_reciprocal = 8'd128;
                5'd5: band_reciprocal = 8'd128;
                5'd6: band_reciprocal = 8'd128;
                5'd7: band_reciprocal = 8'd128;
                5'd8: band_reciprocal = 8'd128;
                5'd9: band_reciprocal = 8'd128;
                5'd10: band_reciprocal = 8'd128;
                5'd11: band_reciprocal = 8'd128;
                5'd12: band_reciprocal = 8'd128;
                5'd13: band_reciprocal = 8'd128;
                5'd14: band_reciprocal = 8'd128;
                5'd15: band_reciprocal = 8'd128;
                5'd16: band_reciprocal = 8'd128;
                5'd17: band_reciprocal = 8'd64;
                5'd18: band_reciprocal = 8'd64;
                5'd19: band_reciprocal = 8'd43;
                5'd20: band_reciprocal = 8'd43;
                5'd21: band_reciprocal = 8'd43;
                5'd22: band_reciprocal = 8'd32;
                5'd23: band_reciprocal = 8'd32;
                5'd24: band_reciprocal = 8'd26;
                5'd25: band_reciprocal = 8'd26;
                5'd26: band_reciprocal = 8'd21;
                5'd27: band_reciprocal = 8'd21;
                5'd28: band_reciprocal = 8'd21;
                5'd29: band_reciprocal = 8'd32;
                5'd30: band_reciprocal = 8'd43;
                5'd31: band_reciprocal = 8'd64;
                default: band_reciprocal = 8'd64;
            endcase
        end else begin
            case (index)
                5'd0: band_reciprocal = 8'd128;
                5'd1: band_reciprocal = 8'd128;
                5'd2: band_reciprocal = 8'd128;
                5'd3: band_reciprocal = 8'd128;
                5'd4: band_reciprocal = 8'd128;
                5'd5: band_reciprocal = 8'd128;
                5'd6: band_reciprocal = 8'd128;
                5'd7: band_reciprocal = 8'd128;
                5'd8: band_reciprocal = 8'd128;
                5'd9: band_reciprocal = 8'd128;
                5'd10: band_reciprocal = 8'd128;
                5'd11: band_reciprocal = 8'd128;
                5'd12: band_reciprocal = 8'd128;
                5'd13: band_reciprocal = 8'd128;
                5'd14: band_reciprocal = 8'd128;
                5'd15: band_reciprocal = 8'd128;
                5'd16: band_reciprocal = 8'd128;
                5'd17: band_reciprocal = 8'd128;
                5'd18: band_reciprocal = 8'd128;
                5'd19: band_reciprocal = 8'd128;
                5'd20: band_reciprocal = 8'd64;
                5'd21: band_reciprocal = 8'd43;
                5'd22: band_reciprocal = 8'd43;
                5'd23: band_reciprocal = 8'd32;
                5'd24: band_reciprocal = 8'd32;
                5'd25: band_reciprocal = 8'd26;
                5'd26: band_reciprocal = 8'd21;
                5'd27: band_reciprocal = 8'd21;
                5'd28: band_reciprocal = 8'd18;
                5'd29: band_reciprocal = 8'd18;
                5'd30: band_reciprocal = 8'd14;
                5'd31: band_reciprocal = 8'd14;
                default: band_reciprocal = 8'd14;
            endcase
        end
    end
endfunction

// 24*log2(M/32)：最高有效位给出整数部分，16 项表给出小数部分。
// 输入先作 Hann 相干增益恢复及频段补偿；门限 32，输出饱和到 255。
function [7:0] magnitude_to_level;
    input [18:0] magnitude;
    reg [4:0] exponent;
    reg [18:0] normalized;
    reg [4:0] fraction;
    reg [8:0] mapped;
    integer bit_index;
    begin
        exponent = 5'd0;
        for (bit_index=0;bit_index<19;bit_index=bit_index+1)
            if (magnitude[bit_index]) exponent = bit_index;
        normalized = magnitude >> ((exponent >= 5'd4) ? exponent - 5'd4 : 5'd0);
        case (normalized[3:0])
            4'd0: fraction = 5'd0;
            4'd1: fraction = 5'd2;
            4'd2: fraction = 5'd4;
            4'd3: fraction = 5'd6;
            4'd4: fraction = 5'd8;
            4'd5: fraction = 5'd9;
            4'd6: fraction = 5'd11;
            4'd7: fraction = 5'd13;
            4'd8: fraction = 5'd14;
            4'd9: fraction = 5'd15;
            4'd10: fraction = 5'd17;
            4'd11: fraction = 5'd18;
            4'd12: fraction = 5'd19;
            4'd13: fraction = 5'd21;
            4'd14: fraction = 5'd22;
            4'd15: fraction = 5'd23;
            default: fraction = 5'd0;
        endcase
        mapped = (exponent - 5'd5) * 9'd24 + {4'd0,fraction};
        if (magnitude <= 19'd32) magnitude_to_level = 8'd0;
        else if (mapped >= 9'd255) magnitude_to_level = 8'hff;
        else magnitude_to_level = mapped[7:0];
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
            // 分拍计算均值、混合、补偿与对数，避免视频域长组合乘加链。
            ST_BAND_COMMIT: begin
                mean_product <= band_sum * reciprocal;
                state <= ST_BAND_MIX;
            end
            ST_BAND_MIX: begin
                mixed_magnitude <= combined_sum[18:2];
                state <= ST_BAND_GAIN;
            end
            ST_BAND_GAIN: begin
                gain_product <= {mixed_magnitude,1'b0} * band_gain;
                state <= ST_BAND_LEVEL;
            end
            ST_BAND_LEVEL: begin
                band_level <= magnitude_to_level(display_magnitude);
                state <= ST_BAND_PUBLISH;
            end
            ST_BAND_PUBLISH: begin
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


// 48 kHz 参考显示链：512/1024/2048 点，逐 bin 欧氏幅度、直接插值、100*ln(1+0.1*M)。
// 参考动态移植自 RP2350_FFT，MIT 声明见 docs/third-party/RP2350_FFT-LICENSE。
// 保留 Hann 窗与采样率；立即上升、重力回落，原始峰值独立驱动呼吸。
module reference_fft_spectrum #(
    parameter integer FFT_POINTS=2048
)(
    input wire clk, input wire rst, input wire sample_valid,
    input wire [23:0] sample_pcm, input wire frame_start,
    output reg [639:0] bars,
    output reg [7:0] breath_radius
);
localparam integer ADDR_W=(FFT_POINTS==2048)?11:(FFT_POINTS==1024)?10:9;
localparam integer LAST_BIN=(FFT_POINTS==2048)?273:(FFT_POINTS==1024)?137:69;
localparam [4:0] ST_IDLE=0,ST_RD_A=1,ST_LATCH_A=2,ST_RD_B=3,ST_LATCH_B=4,
    ST_M0=5,ST_M1=6,ST_M2=7,ST_M3=8,ST_CALC=9,ST_WR_A=10,ST_WR_B=11,
    ST_SCAN_RD=12,ST_SCAN_EVAL=13,ST_SQUARE_I=14,ST_SQRT=15,ST_MAG_WRITE=16,
    ST_BAR_RD_A=17,ST_BAR_A=18,ST_BAR_RD_B=19,ST_BAR_B=20,
    ST_BLEND=21,ST_LOG=22,ST_BAR_WRITE=23,ST_INIT=24;
reg [4:0] state;
reg capture_bank,process_bank;
reg [ADDR_W-1:0] sample_count,group_base,pair_index,step,scan_bin;
reg [3:0] stage;
reg [31:0] a_data,b_data,twiddle_word,p0,p1,p2,p3,result_a,result_b;
wire [31:0] read_data,bank0_q,bank1_q;
reg [31:0] square_sum,sqrt_remainder;
reg [15:0] sqrt_root;
reg [4:0] sqrt_count;
reg [23:0] history_q;
reg [6:0] bar_index;
reg [18:0] magnitude_a,magnitude_b;
reg [27:0] interpolated_product;
reg [18:0] raw_peak,peak_envelope;
reg [7:0] radius_build;
reg [7:0] bar_level;
reg [639:0] bars_build;
reg pending_valid,frame_start_d;
wire [16:0] position_2048=reference_position(bar_index);
wire [16:0] position=position_2048>>(11-ADDR_W);
wire [7:0] fraction=position[7:0];
wire [8:0] magnitude_address= (state==ST_BAR_RD_A)?position[16:8]:
    (state==ST_BAR_RD_B)?position[16:8]+9'd1:scan_bin[8:0];
// 读写地址同为 9 位、深度统一为 512，覆盖 2048 点模式的最高 bin273。
// 幅度换算成参考 M 的 Q8，速度为参考幅度单位/更新；两者共用一组 RAM。
(* ram_style="bram" *) reg [23:0] magnitude_memory [0:511];
wire [18:0] raw_m_q8=({3'd0,sqrt_root}<<3)-{3'd0,sqrt_root};
wire [18:0] held_m_q8=history_q[18:0];
wire [4:0] fall_speed=history_q[23:19];
wire immediate_rise=raw_m_q8>held_m_q8;
wire [18:0] fall_step={6'd0,fall_speed,8'd0};
// 精确保留参考的分支：能减速度则减速度，否则每次减 1；零附近截断。
wire [18:0] falling_m_q8=(held_m_q8>fall_step)?held_m_q8-fall_step:
    (held_m_q8>19'd256)?held_m_q8-19'd256:19'd0;
wire [18:0] smooth_magnitude=immediate_rise?raw_m_q8:falling_m_q8;
wire [4:0] next_fall_speed=immediate_rise?5'd0:
    (fall_speed<5'd20)?fall_speed+5'd1:5'd20;
// bin0 不混入音乐低音；保持原设计的直流排除，不新增去直流滤波器。
wire [23:0] stored_magnitude=(scan_bin==0)?24'd0:{next_fall_speed,smooth_magnitude};
always @(posedge clk) begin
    if (state==ST_INIT) magnitude_memory[scan_bin[8:0]]<=24'd0;
    else if (state==ST_MAG_WRITE && scan_bin<=LAST_BIN) magnitude_memory[scan_bin[8:0]]<=stored_magnitude;
    if ((state==ST_SCAN_RD && scan_bin<=LAST_BIN) || state==ST_BAR_RD_A || state==ST_BAR_RD_B)
        history_q<=magnitude_memory[magnitude_address];
end
wire capture_we=sample_valid && state!=ST_INIT;
wire process_we=(state==ST_WR_A)||(state==ST_WR_B);
wire read_en=(state==ST_RD_A)||(state==ST_RD_B)||(state==ST_SCAN_RD);
wire [ADDR_W-1:0] a_addr=group_base+pair_index;
wire [ADDR_W-1:0] b_addr=group_base+pair_index+step;
wire [ADDR_W-1:0] read_addr=(state==ST_RD_A)?a_addr:(state==ST_RD_B)?b_addr:scan_bin;
wire [ADDR_W-1:0] write_addr=(state==ST_WR_A)?a_addr:b_addr;
wire [31:0] write_data=(state==ST_WR_A)?result_a:result_b;
wire [ADDR_W-1:0] capture_addr;
wire [8:0] window_phase=sample_count>>(ADDR_W-9);
wire [8:0] window_fold=(window_phase>9'd256)?(10'd512-{1'b0,window_phase}):window_phase;
wire [7:0] window_address=(window_fold>9'd128)?(9'd256-window_fold):window_fold[7:0];
wire [7:0] window_quarter=hann_quarter(window_address[7:1]);
wire [8:0] window_gain=(window_fold>9'd128)?(9'd256-{1'b0,window_quarter}):{1'b0,window_quarter};
wire signed [15:0] pcm16=sample_pcm[23:8];
wire signed [25:0] window_product=pcm16*$signed({1'b0,window_gain});
wire signed [25:0] window_shifted=window_product>>>8;
wire [15:0] windowed_pcm=window_shifted[15:0];
wire [9:0] twiddle_index=pair_index<<(10-stage);
// 同一乘法器复用蝶形和幅度平方，避免增加 DSP。
wire signed [15:0] mul_a=(state==ST_SCAN_EVAL)?read_data[31:16]:
    (state==ST_SQUARE_I)?b_data[15:0]:
    ((state==ST_M0)||(state==ST_M2))?b_data[31:16]:b_data[15:0];
wire signed [15:0] mul_b=(state==ST_SCAN_EVAL)?read_data[31:16]:
    (state==ST_SQUARE_I)?b_data[15:0]:
    ((state==ST_M0)||(state==ST_M3))?twiddle_word[31:16]:twiddle_word[15:0];
wire signed [31:0] product=mul_a*mul_b;
wire signed [32:0] real_product=$signed({p0[31],p0})-$signed({p1[31],p1});
wire signed [32:0] imag_product=$signed({p2[31],p2})+$signed({p3[31],p3});
wire signed [17:0] rotated_real=real_product>>>15;
wire signed [17:0] rotated_imag=imag_product>>>15;
wire signed [17:0] ar=$signed({{2{a_data[31]}},a_data[31:16]});
wire signed [17:0] ai=$signed({{2{a_data[15]}},a_data[15:0]});
// 逐两位恢复平方根；16 拍得到 floor(sqrt(re^2+im^2))。
wire [33:0] sqrt_shift={sqrt_remainder, square_sum[31:30]};
wire [33:0] sqrt_trial={16'd0,sqrt_root,2'b01};
wire sqrt_accept=sqrt_shift>=sqrt_trial;
// 归一化 FFT 除以 N；恢复到参考 2048 点、满幅归一化、Flat-top 等效增益。
// M 的 Q8 值约为原始 magnitude*6.8985，取 7；误差约 1.5%。
// 已在入历史 RAM 前换算，插值后无需再次乘 7。
wire [18:0] reference_m_q8=interpolated_product[26:8];
wire [23:0] log_argument=24'd256+(({5'd0,reference_m_q8}+24'd5)/10);
// 参考呼吸先在原始幅度域做 0.8/0.2 平滑，再做 3*log2(M+1)。
wire [21:0] envelope_sum={3'd0,peak_envelope}+{1'b0,raw_peak,2'd0}+22'd2;
wire [18:0] next_envelope=envelope_sum/22'd5;
function [4:0] radius_offset;
    input [18:0] m_q8;
    reg [19:0] argument;
    integer offset;
    begin
        argument={1'b0,m_q8}+20'd256;
        radius_offset=5'd0;
        // 3*log2(x) 的整数阈值：ceil(256*2^(offset/3))。
        for(offset=1;offset<=20;offset=offset+1) begin
            case(offset)
                1: if(argument>=20'd323) radius_offset=5'd1;
                2: if(argument>=20'd407) radius_offset=5'd2;
                3: if(argument>=20'd512) radius_offset=5'd3;
                4: if(argument>=20'd646) radius_offset=5'd4;
                5: if(argument>=20'd813) radius_offset=5'd5;
                6: if(argument>=20'd1024) radius_offset=5'd6;
                7: if(argument>=20'd1291) radius_offset=5'd7;
                8: if(argument>=20'd1626) radius_offset=5'd8;
                9: if(argument>=20'd2048) radius_offset=5'd9;
                10: if(argument>=20'd2581) radius_offset=5'd10;
                11: if(argument>=20'd3251) radius_offset=5'd11;
                12: if(argument>=20'd4096) radius_offset=5'd12;
                13: if(argument>=20'd5161) radius_offset=5'd13;
                14: if(argument>=20'd6502) radius_offset=5'd14;
                15: if(argument>=20'd8192) radius_offset=5'd15;
                16: if(argument>=20'd10322) radius_offset=5'd16;
                17: if(argument>=20'd13004) radius_offset=5'd17;
                18: if(argument>=20'd16384) radius_offset=5'd18;
                19: if(argument>=20'd20643) radius_offset=5'd19;
                20: if(argument>=20'd26008) radius_offset=5'd20;
                default: begin end
            endcase
        end
    end
endfunction
function [7:0] reference_level;
    input [23:0] argument;
    integer bit_index;
    reg [4:0] msb;
    reg [23:0] normalized;
    reg [11:0] result;
    begin
        msb=0;
        for(bit_index=0;bit_index<24;bit_index=bit_index+1)
            if(argument[bit_index]) msb=bit_index;
        normalized=argument>>(msb-6);
        // 69.3125 近似 100*ln(2)，保留四位小数后再取整。
        result=((msb-8)*12'd1109+12'd8)>>4;
        result=result+reference_log_fraction(normalized[5:0]);
        reference_level=(result>240)?8'd240:result[7:0];
    end
endfunction
function [ADDR_W-1:0] bit_reverse;
    input [ADDR_W-1:0] value;
    integer n;
    begin
        for (n=0;n<ADDR_W;n=n+1)
            bit_reverse[n] = value[ADDR_W-1-n];
    end
endfunction
function [15:0] sat16;
    input signed [17:0] value;
    begin
        if (value > 18'sd32767) sat16=16'h7fff;
        else if (value < -18'sd32768) sat16=16'h8000;
        else sat16=value[15:0];
    end
endfunction
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
assign capture_addr=bit_reverse(sample_count);
// BEGIN REFERENCE TABLES
// 由 generate_reference_fft_tables.py 生成，不使用外部 ROM 文件。
function [31:0] reference_twiddle;
    input [9:0] index;
    begin
        case (index)
            10'd0: reference_twiddle = 32'h7fff0000;
            10'd1: reference_twiddle = 32'h7fffff9b;
            10'd2: reference_twiddle = 32'h7ffeff37;
            10'd3: reference_twiddle = 32'h7ffefed2;
            10'd4: reference_twiddle = 32'h7ffdfe6e;
            10'd5: reference_twiddle = 32'h7ffbfe09;
            10'd6: reference_twiddle = 32'h7ff9fda5;
            10'd7: reference_twiddle = 32'h7ff7fd40;
            10'd8: reference_twiddle = 32'h7ff5fcdc;
            10'd9: reference_twiddle = 32'h7ff3fc77;
            10'd10: reference_twiddle = 32'h7ff0fc13;
            10'd11: reference_twiddle = 32'h7fecfbae;
            10'd12: reference_twiddle = 32'h7fe9fb4a;
            10'd13: reference_twiddle = 32'h7fe5fae5;
            10'd14: reference_twiddle = 32'h7fe1fa81;
            10'd15: reference_twiddle = 32'h7fdcfa1d;
            10'd16: reference_twiddle = 32'h7fd8f9b8;
            10'd17: reference_twiddle = 32'h7fd2f954;
            10'd18: reference_twiddle = 32'h7fcdf8ef;
            10'd19: reference_twiddle = 32'h7fc7f88b;
            10'd20: reference_twiddle = 32'h7fc1f827;
            10'd21: reference_twiddle = 32'h7fbbf7c2;
            10'd22: reference_twiddle = 32'h7fb4f75e;
            10'd23: reference_twiddle = 32'h7fadf6fa;
            10'd24: reference_twiddle = 32'h7fa6f696;
            10'd25: reference_twiddle = 32'h7f9ff631;
            10'd26: reference_twiddle = 32'h7f97f5cd;
            10'd27: reference_twiddle = 32'h7f8ff569;
            10'd28: reference_twiddle = 32'h7f86f505;
            10'd29: reference_twiddle = 32'h7f7df4a1;
            10'd30: reference_twiddle = 32'h7f74f43c;
            10'd31: reference_twiddle = 32'h7f6bf3d8;
            10'd32: reference_twiddle = 32'h7f61f374;
            10'd33: reference_twiddle = 32'h7f57f310;
            10'd34: reference_twiddle = 32'h7f4df2ac;
            10'd35: reference_twiddle = 32'h7f42f248;
            10'd36: reference_twiddle = 32'h7f37f1e4;
            10'd37: reference_twiddle = 32'h7f2cf180;
            10'd38: reference_twiddle = 32'h7f21f11d;
            10'd39: reference_twiddle = 32'h7f15f0b9;
            10'd40: reference_twiddle = 32'h7f09f055;
            10'd41: reference_twiddle = 32'h7efceff1;
            10'd42: reference_twiddle = 32'h7eefef8e;
            10'd43: reference_twiddle = 32'h7ee2ef2a;
            10'd44: reference_twiddle = 32'h7ed5eec6;
            10'd45: reference_twiddle = 32'h7ec7ee63;
            10'd46: reference_twiddle = 32'h7eb9edff;
            10'd47: reference_twiddle = 32'h7eabed9c;
            10'd48: reference_twiddle = 32'h7e9ced38;
            10'd49: reference_twiddle = 32'h7e8decd5;
            10'd50: reference_twiddle = 32'h7e7eec71;
            10'd51: reference_twiddle = 32'h7e6fec0e;
            10'd52: reference_twiddle = 32'h7e5febab;
            10'd53: reference_twiddle = 32'h7e4feb47;
            10'd54: reference_twiddle = 32'h7e3eeae4;
            10'd55: reference_twiddle = 32'h7e2eea81;
            10'd56: reference_twiddle = 32'h7e1dea1e;
            10'd57: reference_twiddle = 32'h7e0be9bb;
            10'd58: reference_twiddle = 32'h7dfae958;
            10'd59: reference_twiddle = 32'h7de8e8f5;
            10'd60: reference_twiddle = 32'h7dd5e892;
            10'd61: reference_twiddle = 32'h7dc3e830;
            10'd62: reference_twiddle = 32'h7db0e7cd;
            10'd63: reference_twiddle = 32'h7d9de76a;
            10'd64: reference_twiddle = 32'h7d89e707;
            10'd65: reference_twiddle = 32'h7d76e6a5;
            10'd66: reference_twiddle = 32'h7d62e642;
            10'd67: reference_twiddle = 32'h7d4de5e0;
            10'd68: reference_twiddle = 32'h7d39e57e;
            10'd69: reference_twiddle = 32'h7d24e51b;
            10'd70: reference_twiddle = 32'h7d0ee4b9;
            10'd71: reference_twiddle = 32'h7cf9e457;
            10'd72: reference_twiddle = 32'h7ce3e3f5;
            10'd73: reference_twiddle = 32'h7ccde393;
            10'd74: reference_twiddle = 32'h7cb6e331;
            10'd75: reference_twiddle = 32'h7c9fe2cf;
            10'd76: reference_twiddle = 32'h7c88e26d;
            10'd77: reference_twiddle = 32'h7c71e20b;
            10'd78: reference_twiddle = 32'h7c59e1a9;
            10'd79: reference_twiddle = 32'h7c41e148;
            10'd80: reference_twiddle = 32'h7c29e0e6;
            10'd81: reference_twiddle = 32'h7c10e085;
            10'd82: reference_twiddle = 32'h7bf8e023;
            10'd83: reference_twiddle = 32'h7bdedfc2;
            10'd84: reference_twiddle = 32'h7bc5df61;
            10'd85: reference_twiddle = 32'h7babdf00;
            10'd86: reference_twiddle = 32'h7b91de9f;
            10'd87: reference_twiddle = 32'h7b77de3e;
            10'd88: reference_twiddle = 32'h7b5cdddd;
            10'd89: reference_twiddle = 32'h7b41dd7c;
            10'd90: reference_twiddle = 32'h7b26dd1b;
            10'd91: reference_twiddle = 32'h7b0adcba;
            10'd92: reference_twiddle = 32'h7aeedc5a;
            10'd93: reference_twiddle = 32'h7ad2dbf9;
            10'd94: reference_twiddle = 32'h7ab6db99;
            10'd95: reference_twiddle = 32'h7a99db38;
            10'd96: reference_twiddle = 32'h7a7cdad8;
            10'd97: reference_twiddle = 32'h7a5fda78;
            10'd98: reference_twiddle = 32'h7a41da18;
            10'd99: reference_twiddle = 32'h7a23d9b8;
            10'd100: reference_twiddle = 32'h7a05d958;
            10'd101: reference_twiddle = 32'h79e6d8f8;
            10'd102: reference_twiddle = 32'h79c8d899;
            10'd103: reference_twiddle = 32'h79a9d839;
            10'd104: reference_twiddle = 32'h7989d7da;
            10'd105: reference_twiddle = 32'h796ad77a;
            10'd106: reference_twiddle = 32'h794ad71b;
            10'd107: reference_twiddle = 32'h7929d6bc;
            10'd108: reference_twiddle = 32'h7909d65d;
            10'd109: reference_twiddle = 32'h78e8d5fe;
            10'd110: reference_twiddle = 32'h78c7d59f;
            10'd111: reference_twiddle = 32'h78a5d540;
            10'd112: reference_twiddle = 32'h7884d4e1;
            10'd113: reference_twiddle = 32'h7862d483;
            10'd114: reference_twiddle = 32'h783fd424;
            10'd115: reference_twiddle = 32'h781dd3c6;
            10'd116: reference_twiddle = 32'h77fad367;
            10'd117: reference_twiddle = 32'h77d7d309;
            10'd118: reference_twiddle = 32'h77b3d2ab;
            10'd119: reference_twiddle = 32'h778fd24d;
            10'd120: reference_twiddle = 32'h776bd1ef;
            10'd121: reference_twiddle = 32'h7747d192;
            10'd122: reference_twiddle = 32'h7722d134;
            10'd123: reference_twiddle = 32'h76fed0d6;
            10'd124: reference_twiddle = 32'h76d8d079;
            10'd125: reference_twiddle = 32'h76b3d01c;
            10'd126: reference_twiddle = 32'h768dcfbf;
            10'd127: reference_twiddle = 32'h7667cf62;
            10'd128: reference_twiddle = 32'h7641cf05;
            10'd129: reference_twiddle = 32'h761acea8;
            10'd130: reference_twiddle = 32'h75f3ce4b;
            10'd131: reference_twiddle = 32'h75cccdef;
            10'd132: reference_twiddle = 32'h75a5cd92;
            10'd133: reference_twiddle = 32'h757dcd36;
            10'd134: reference_twiddle = 32'h7555ccda;
            10'd135: reference_twiddle = 32'h752dcc7d;
            10'd136: reference_twiddle = 32'h7504cc21;
            10'd137: reference_twiddle = 32'h74dbcbc6;
            10'd138: reference_twiddle = 32'h74b2cb6a;
            10'd139: reference_twiddle = 32'h7488cb0e;
            10'd140: reference_twiddle = 32'h745fcab3;
            10'd141: reference_twiddle = 32'h7435ca58;
            10'd142: reference_twiddle = 32'h740ac9fc;
            10'd143: reference_twiddle = 32'h73e0c9a1;
            10'd144: reference_twiddle = 32'h73b5c946;
            10'd145: reference_twiddle = 32'h738ac8eb;
            10'd146: reference_twiddle = 32'h735ec891;
            10'd147: reference_twiddle = 32'h7333c836;
            10'd148: reference_twiddle = 32'h7307c7dc;
            10'd149: reference_twiddle = 32'h72dbc782;
            10'd150: reference_twiddle = 32'h72aec727;
            10'd151: reference_twiddle = 32'h7281c6cd;
            10'd152: reference_twiddle = 32'h7254c674;
            10'd153: reference_twiddle = 32'h7227c61a;
            10'd154: reference_twiddle = 32'h71f9c5c0;
            10'd155: reference_twiddle = 32'h71cbc567;
            10'd156: reference_twiddle = 32'h719dc50e;
            10'd157: reference_twiddle = 32'h716fc4b4;
            10'd158: reference_twiddle = 32'h7140c45b;
            10'd159: reference_twiddle = 32'h7111c402;
            10'd160: reference_twiddle = 32'h70e2c3aa;
            10'd161: reference_twiddle = 32'h70b2c351;
            10'd162: reference_twiddle = 32'h7083c2f9;
            10'd163: reference_twiddle = 32'h7053c2a0;
            10'd164: reference_twiddle = 32'h7022c248;
            10'd165: reference_twiddle = 32'h6ff2c1f0;
            10'd166: reference_twiddle = 32'h6fc1c198;
            10'd167: reference_twiddle = 32'h6f90c141;
            10'd168: reference_twiddle = 32'h6f5ec0e9;
            10'd169: reference_twiddle = 32'h6f2cc092;
            10'd170: reference_twiddle = 32'h6efbc03b;
            10'd171: reference_twiddle = 32'h6ec8bfe3;
            10'd172: reference_twiddle = 32'h6e96bf8d;
            10'd173: reference_twiddle = 32'h6e63bf36;
            10'd174: reference_twiddle = 32'h6e30bedf;
            10'd175: reference_twiddle = 32'h6dfdbe89;
            10'd176: reference_twiddle = 32'h6dc9be32;
            10'd177: reference_twiddle = 32'h6d95bddc;
            10'd178: reference_twiddle = 32'h6d61bd86;
            10'd179: reference_twiddle = 32'h6d2dbd30;
            10'd180: reference_twiddle = 32'h6cf8bcdb;
            10'd181: reference_twiddle = 32'h6cc3bc85;
            10'd182: reference_twiddle = 32'h6c8ebc30;
            10'd183: reference_twiddle = 32'h6c59bbdb;
            10'd184: reference_twiddle = 32'h6c23bb86;
            10'd185: reference_twiddle = 32'h6bedbb31;
            10'd186: reference_twiddle = 32'h6bb7badc;
            10'd187: reference_twiddle = 32'h6b81ba88;
            10'd188: reference_twiddle = 32'h6b4aba33;
            10'd189: reference_twiddle = 32'h6b13b9df;
            10'd190: reference_twiddle = 32'h6adcb98b;
            10'd191: reference_twiddle = 32'h6aa4b937;
            10'd192: reference_twiddle = 32'h6a6db8e4;
            10'd193: reference_twiddle = 32'h6a35b890;
            10'd194: reference_twiddle = 32'h69fdb83d;
            10'd195: reference_twiddle = 32'h69c4b7ea;
            10'd196: reference_twiddle = 32'h698bb797;
            10'd197: reference_twiddle = 32'h6952b744;
            10'd198: reference_twiddle = 32'h6919b6f1;
            10'd199: reference_twiddle = 32'h68e0b69f;
            10'd200: reference_twiddle = 32'h68a6b64c;
            10'd201: reference_twiddle = 32'h686cb5fa;
            10'd202: reference_twiddle = 32'h6832b5a8;
            10'd203: reference_twiddle = 32'h67f7b557;
            10'd204: reference_twiddle = 32'h67bcb505;
            10'd205: reference_twiddle = 32'h6781b4b4;
            10'd206: reference_twiddle = 32'h6746b463;
            10'd207: reference_twiddle = 32'h670ab412;
            10'd208: reference_twiddle = 32'h66cfb3c1;
            10'd209: reference_twiddle = 32'h6693b370;
            10'd210: reference_twiddle = 32'h6656b320;
            10'd211: reference_twiddle = 32'h661ab2cf;
            10'd212: reference_twiddle = 32'h65ddb27f;
            10'd213: reference_twiddle = 32'h65a0b22f;
            10'd214: reference_twiddle = 32'h6563b1e0;
            10'd215: reference_twiddle = 32'h6525b190;
            10'd216: reference_twiddle = 32'h64e8b141;
            10'd217: reference_twiddle = 32'h64aab0f2;
            10'd218: reference_twiddle = 32'h646cb0a3;
            10'd219: reference_twiddle = 32'h642db054;
            10'd220: reference_twiddle = 32'h63eeb005;
            10'd221: reference_twiddle = 32'h63afafb7;
            10'd222: reference_twiddle = 32'h6370af69;
            10'd223: reference_twiddle = 32'h6331af1b;
            10'd224: reference_twiddle = 32'h62f1aecd;
            10'd225: reference_twiddle = 32'h62b1ae7f;
            10'd226: reference_twiddle = 32'h6271ae32;
            10'd227: reference_twiddle = 32'h6231ade5;
            10'd228: reference_twiddle = 32'h61f0ad98;
            10'd229: reference_twiddle = 32'h61afad4b;
            10'd230: reference_twiddle = 32'h616eacfe;
            10'd231: reference_twiddle = 32'h612dacb2;
            10'd232: reference_twiddle = 32'h60ebac65;
            10'd233: reference_twiddle = 32'h60aaac19;
            10'd234: reference_twiddle = 32'h6068abce;
            10'd235: reference_twiddle = 32'h6025ab82;
            10'd236: reference_twiddle = 32'h5fe3ab37;
            10'd237: reference_twiddle = 32'h5fa0aaeb;
            10'd238: reference_twiddle = 32'h5f5daaa0;
            10'd239: reference_twiddle = 32'h5f1aaa56;
            10'd240: reference_twiddle = 32'h5ed7aa0b;
            10'd241: reference_twiddle = 32'h5e93a9c1;
            10'd242: reference_twiddle = 32'h5e4fa976;
            10'd243: reference_twiddle = 32'h5e0ba92d;
            10'd244: reference_twiddle = 32'h5dc7a8e3;
            10'd245: reference_twiddle = 32'h5d82a899;
            10'd246: reference_twiddle = 32'h5d3ea850;
            10'd247: reference_twiddle = 32'h5cf9a807;
            10'd248: reference_twiddle = 32'h5cb3a7be;
            10'd249: reference_twiddle = 32'h5c6ea775;
            10'd250: reference_twiddle = 32'h5c28a72d;
            10'd251: reference_twiddle = 32'h5be2a6e4;
            10'd252: reference_twiddle = 32'h5b9ca69c;
            10'd253: reference_twiddle = 32'h5b56a654;
            10'd254: reference_twiddle = 32'h5b0fa60d;
            10'd255: reference_twiddle = 32'h5ac9a5c5;
            10'd256: reference_twiddle = 32'h5a82a57e;
            10'd257: reference_twiddle = 32'h5a3ba537;
            10'd258: reference_twiddle = 32'h59f3a4f1;
            10'd259: reference_twiddle = 32'h59aca4aa;
            10'd260: reference_twiddle = 32'h5964a464;
            10'd261: reference_twiddle = 32'h591ca41e;
            10'd262: reference_twiddle = 32'h58d3a3d8;
            10'd263: reference_twiddle = 32'h588ba392;
            10'd264: reference_twiddle = 32'h5842a34d;
            10'd265: reference_twiddle = 32'h57f9a307;
            10'd266: reference_twiddle = 32'h57b0a2c2;
            10'd267: reference_twiddle = 32'h5767a27e;
            10'd268: reference_twiddle = 32'h571da239;
            10'd269: reference_twiddle = 32'h56d3a1f5;
            10'd270: reference_twiddle = 32'h568aa1b1;
            10'd271: reference_twiddle = 32'h563fa16d;
            10'd272: reference_twiddle = 32'h55f5a129;
            10'd273: reference_twiddle = 32'h55aaa0e6;
            10'd274: reference_twiddle = 32'h5560a0a3;
            10'd275: reference_twiddle = 32'h5515a060;
            10'd276: reference_twiddle = 32'h54c9a01d;
            10'd277: reference_twiddle = 32'h547e9fdb;
            10'd278: reference_twiddle = 32'h54329f98;
            10'd279: reference_twiddle = 32'h53e79f56;
            10'd280: reference_twiddle = 32'h539b9f15;
            10'd281: reference_twiddle = 32'h534e9ed3;
            10'd282: reference_twiddle = 32'h53029e92;
            10'd283: reference_twiddle = 32'h52b59e51;
            10'd284: reference_twiddle = 32'h52689e10;
            10'd285: reference_twiddle = 32'h521b9dcf;
            10'd286: reference_twiddle = 32'h51ce9d8f;
            10'd287: reference_twiddle = 32'h51819d4f;
            10'd288: reference_twiddle = 32'h51339d0f;
            10'd289: reference_twiddle = 32'h50e59ccf;
            10'd290: reference_twiddle = 32'h50979c90;
            10'd291: reference_twiddle = 32'h50499c51;
            10'd292: reference_twiddle = 32'h4ffb9c12;
            10'd293: reference_twiddle = 32'h4fac9bd3;
            10'd294: reference_twiddle = 32'h4f5d9b94;
            10'd295: reference_twiddle = 32'h4f0e9b56;
            10'd296: reference_twiddle = 32'h4ebf9b18;
            10'd297: reference_twiddle = 32'h4e709adb;
            10'd298: reference_twiddle = 32'h4e209a9d;
            10'd299: reference_twiddle = 32'h4dd19a60;
            10'd300: reference_twiddle = 32'h4d819a23;
            10'd301: reference_twiddle = 32'h4d3199e6;
            10'd302: reference_twiddle = 32'h4ce099aa;
            10'd303: reference_twiddle = 32'h4c90996d;
            10'd304: reference_twiddle = 32'h4c3f9931;
            10'd305: reference_twiddle = 32'h4bee98f6;
            10'd306: reference_twiddle = 32'h4b9d98ba;
            10'd307: reference_twiddle = 32'h4b4c987f;
            10'd308: reference_twiddle = 32'h4afb9844;
            10'd309: reference_twiddle = 32'h4aa99809;
            10'd310: reference_twiddle = 32'h4a5897ce;
            10'd311: reference_twiddle = 32'h4a069794;
            10'd312: reference_twiddle = 32'h49b4975a;
            10'd313: reference_twiddle = 32'h49619720;
            10'd314: reference_twiddle = 32'h490f96e7;
            10'd315: reference_twiddle = 32'h48bc96ae;
            10'd316: reference_twiddle = 32'h48699675;
            10'd317: reference_twiddle = 32'h4816963c;
            10'd318: reference_twiddle = 32'h47c39603;
            10'd319: reference_twiddle = 32'h477095cb;
            10'd320: reference_twiddle = 32'h471c9593;
            10'd321: reference_twiddle = 32'h46c9955c;
            10'd322: reference_twiddle = 32'h46759524;
            10'd323: reference_twiddle = 32'h462194ed;
            10'd324: reference_twiddle = 32'h45cd94b6;
            10'd325: reference_twiddle = 32'h4578947f;
            10'd326: reference_twiddle = 32'h45249449;
            10'd327: reference_twiddle = 32'h44cf9413;
            10'd328: reference_twiddle = 32'h447a93dd;
            10'd329: reference_twiddle = 32'h442593a7;
            10'd330: reference_twiddle = 32'h43d09372;
            10'd331: reference_twiddle = 32'h437b933d;
            10'd332: reference_twiddle = 32'h43259308;
            10'd333: reference_twiddle = 32'h42d092d3;
            10'd334: reference_twiddle = 32'h427a929f;
            10'd335: reference_twiddle = 32'h4224926b;
            10'd336: reference_twiddle = 32'h41ce9237;
            10'd337: reference_twiddle = 32'h41779203;
            10'd338: reference_twiddle = 32'h412191d0;
            10'd339: reference_twiddle = 32'h40ca919d;
            10'd340: reference_twiddle = 32'h4073916a;
            10'd341: reference_twiddle = 32'h401d9138;
            10'd342: reference_twiddle = 32'h3fc59105;
            10'd343: reference_twiddle = 32'h3f6e90d4;
            10'd344: reference_twiddle = 32'h3f1790a2;
            10'd345: reference_twiddle = 32'h3ebf9070;
            10'd346: reference_twiddle = 32'h3e68903f;
            10'd347: reference_twiddle = 32'h3e10900e;
            10'd348: reference_twiddle = 32'h3db88fde;
            10'd349: reference_twiddle = 32'h3d608fad;
            10'd350: reference_twiddle = 32'h3d078f7d;
            10'd351: reference_twiddle = 32'h3caf8f4e;
            10'd352: reference_twiddle = 32'h3c568f1e;
            10'd353: reference_twiddle = 32'h3bfe8eef;
            10'd354: reference_twiddle = 32'h3ba58ec0;
            10'd355: reference_twiddle = 32'h3b4c8e91;
            10'd356: reference_twiddle = 32'h3af28e63;
            10'd357: reference_twiddle = 32'h3a998e35;
            10'd358: reference_twiddle = 32'h3a408e07;
            10'd359: reference_twiddle = 32'h39e68dd9;
            10'd360: reference_twiddle = 32'h398c8dac;
            10'd361: reference_twiddle = 32'h39338d7f;
            10'd362: reference_twiddle = 32'h38d98d52;
            10'd363: reference_twiddle = 32'h387e8d25;
            10'd364: reference_twiddle = 32'h38248cf9;
            10'd365: reference_twiddle = 32'h37ca8ccd;
            10'd366: reference_twiddle = 32'h376f8ca2;
            10'd367: reference_twiddle = 32'h37158c76;
            10'd368: reference_twiddle = 32'h36ba8c4b;
            10'd369: reference_twiddle = 32'h365f8c20;
            10'd370: reference_twiddle = 32'h36048bf6;
            10'd371: reference_twiddle = 32'h35a88bcb;
            10'd372: reference_twiddle = 32'h354d8ba1;
            10'd373: reference_twiddle = 32'h34f28b78;
            10'd374: reference_twiddle = 32'h34968b4e;
            10'd375: reference_twiddle = 32'h343a8b25;
            10'd376: reference_twiddle = 32'h33df8afc;
            10'd377: reference_twiddle = 32'h33838ad3;
            10'd378: reference_twiddle = 32'h33268aab;
            10'd379: reference_twiddle = 32'h32ca8a83;
            10'd380: reference_twiddle = 32'h326e8a5b;
            10'd381: reference_twiddle = 32'h32118a34;
            10'd382: reference_twiddle = 32'h31b58a0d;
            10'd383: reference_twiddle = 32'h315889e6;
            10'd384: reference_twiddle = 32'h30fb89bf;
            10'd385: reference_twiddle = 32'h309e8999;
            10'd386: reference_twiddle = 32'h30418973;
            10'd387: reference_twiddle = 32'h2fe4894d;
            10'd388: reference_twiddle = 32'h2f878928;
            10'd389: reference_twiddle = 32'h2f2a8902;
            10'd390: reference_twiddle = 32'h2ecc88de;
            10'd391: reference_twiddle = 32'h2e6e88b9;
            10'd392: reference_twiddle = 32'h2e118895;
            10'd393: reference_twiddle = 32'h2db38871;
            10'd394: reference_twiddle = 32'h2d55884d;
            10'd395: reference_twiddle = 32'h2cf78829;
            10'd396: reference_twiddle = 32'h2c998806;
            10'd397: reference_twiddle = 32'h2c3a87e3;
            10'd398: reference_twiddle = 32'h2bdc87c1;
            10'd399: reference_twiddle = 32'h2b7d879e;
            10'd400: reference_twiddle = 32'h2b1f877c;
            10'd401: reference_twiddle = 32'h2ac0875b;
            10'd402: reference_twiddle = 32'h2a618739;
            10'd403: reference_twiddle = 32'h2a028718;
            10'd404: reference_twiddle = 32'h29a386f7;
            10'd405: reference_twiddle = 32'h294486d7;
            10'd406: reference_twiddle = 32'h28e586b6;
            10'd407: reference_twiddle = 32'h28868696;
            10'd408: reference_twiddle = 32'h28268677;
            10'd409: reference_twiddle = 32'h27c78657;
            10'd410: reference_twiddle = 32'h27678638;
            10'd411: reference_twiddle = 32'h2708861a;
            10'd412: reference_twiddle = 32'h26a885fb;
            10'd413: reference_twiddle = 32'h264885dd;
            10'd414: reference_twiddle = 32'h25e885bf;
            10'd415: reference_twiddle = 32'h258885a1;
            10'd416: reference_twiddle = 32'h25288584;
            10'd417: reference_twiddle = 32'h24c88567;
            10'd418: reference_twiddle = 32'h2467854a;
            10'd419: reference_twiddle = 32'h2407852e;
            10'd420: reference_twiddle = 32'h23a68512;
            10'd421: reference_twiddle = 32'h234684f6;
            10'd422: reference_twiddle = 32'h22e584da;
            10'd423: reference_twiddle = 32'h228484bf;
            10'd424: reference_twiddle = 32'h222384a4;
            10'd425: reference_twiddle = 32'h21c28489;
            10'd426: reference_twiddle = 32'h2161846f;
            10'd427: reference_twiddle = 32'h21008455;
            10'd428: reference_twiddle = 32'h209f843b;
            10'd429: reference_twiddle = 32'h203e8422;
            10'd430: reference_twiddle = 32'h1fdd8408;
            10'd431: reference_twiddle = 32'h1f7b83f0;
            10'd432: reference_twiddle = 32'h1f1a83d7;
            10'd433: reference_twiddle = 32'h1eb883bf;
            10'd434: reference_twiddle = 32'h1e5783a7;
            10'd435: reference_twiddle = 32'h1df5838f;
            10'd436: reference_twiddle = 32'h1d938378;
            10'd437: reference_twiddle = 32'h1d318361;
            10'd438: reference_twiddle = 32'h1ccf834a;
            10'd439: reference_twiddle = 32'h1c6d8333;
            10'd440: reference_twiddle = 32'h1c0b831d;
            10'd441: reference_twiddle = 32'h1ba98307;
            10'd442: reference_twiddle = 32'h1b4782f2;
            10'd443: reference_twiddle = 32'h1ae582dc;
            10'd444: reference_twiddle = 32'h1a8282c7;
            10'd445: reference_twiddle = 32'h1a2082b3;
            10'd446: reference_twiddle = 32'h19be829e;
            10'd447: reference_twiddle = 32'h195b828a;
            10'd448: reference_twiddle = 32'h18f98277;
            10'd449: reference_twiddle = 32'h18968263;
            10'd450: reference_twiddle = 32'h18338250;
            10'd451: reference_twiddle = 32'h17d0823d;
            10'd452: reference_twiddle = 32'h176e822b;
            10'd453: reference_twiddle = 32'h170b8218;
            10'd454: reference_twiddle = 32'h16a88206;
            10'd455: reference_twiddle = 32'h164581f5;
            10'd456: reference_twiddle = 32'h15e281e3;
            10'd457: reference_twiddle = 32'h157f81d2;
            10'd458: reference_twiddle = 32'h151c81c2;
            10'd459: reference_twiddle = 32'h14b981b1;
            10'd460: reference_twiddle = 32'h145581a1;
            10'd461: reference_twiddle = 32'h13f28191;
            10'd462: reference_twiddle = 32'h138f8182;
            10'd463: reference_twiddle = 32'h132b8173;
            10'd464: reference_twiddle = 32'h12c88164;
            10'd465: reference_twiddle = 32'h12648155;
            10'd466: reference_twiddle = 32'h12018147;
            10'd467: reference_twiddle = 32'h119d8139;
            10'd468: reference_twiddle = 32'h113a812b;
            10'd469: reference_twiddle = 32'h10d6811e;
            10'd470: reference_twiddle = 32'h10728111;
            10'd471: reference_twiddle = 32'h100f8104;
            10'd472: reference_twiddle = 32'h0fab80f7;
            10'd473: reference_twiddle = 32'h0f4780eb;
            10'd474: reference_twiddle = 32'h0ee380df;
            10'd475: reference_twiddle = 32'h0e8080d4;
            10'd476: reference_twiddle = 32'h0e1c80c9;
            10'd477: reference_twiddle = 32'h0db880be;
            10'd478: reference_twiddle = 32'h0d5480b3;
            10'd479: reference_twiddle = 32'h0cf080a9;
            10'd480: reference_twiddle = 32'h0c8c809f;
            10'd481: reference_twiddle = 32'h0c288095;
            10'd482: reference_twiddle = 32'h0bc4808c;
            10'd483: reference_twiddle = 32'h0b5f8083;
            10'd484: reference_twiddle = 32'h0afb807a;
            10'd485: reference_twiddle = 32'h0a978071;
            10'd486: reference_twiddle = 32'h0a338069;
            10'd487: reference_twiddle = 32'h09cf8061;
            10'd488: reference_twiddle = 32'h096a805a;
            10'd489: reference_twiddle = 32'h09068053;
            10'd490: reference_twiddle = 32'h08a2804c;
            10'd491: reference_twiddle = 32'h083e8045;
            10'd492: reference_twiddle = 32'h07d9803f;
            10'd493: reference_twiddle = 32'h07758039;
            10'd494: reference_twiddle = 32'h07118033;
            10'd495: reference_twiddle = 32'h06ac802e;
            10'd496: reference_twiddle = 32'h06488028;
            10'd497: reference_twiddle = 32'h05e38024;
            10'd498: reference_twiddle = 32'h057f801f;
            10'd499: reference_twiddle = 32'h051b801b;
            10'd500: reference_twiddle = 32'h04b68017;
            10'd501: reference_twiddle = 32'h04528014;
            10'd502: reference_twiddle = 32'h03ed8010;
            10'd503: reference_twiddle = 32'h0389800d;
            10'd504: reference_twiddle = 32'h0324800b;
            10'd505: reference_twiddle = 32'h02c08009;
            10'd506: reference_twiddle = 32'h025b8007;
            10'd507: reference_twiddle = 32'h01f78005;
            10'd508: reference_twiddle = 32'h01928003;
            10'd509: reference_twiddle = 32'h012e8002;
            10'd510: reference_twiddle = 32'h00c98002;
            10'd511: reference_twiddle = 32'h00658001;
            10'd512: reference_twiddle = 32'h00008001;
            10'd513: reference_twiddle = 32'hff9b8001;
            10'd514: reference_twiddle = 32'hff378002;
            10'd515: reference_twiddle = 32'hfed28002;
            10'd516: reference_twiddle = 32'hfe6e8003;
            10'd517: reference_twiddle = 32'hfe098005;
            10'd518: reference_twiddle = 32'hfda58007;
            10'd519: reference_twiddle = 32'hfd408009;
            10'd520: reference_twiddle = 32'hfcdc800b;
            10'd521: reference_twiddle = 32'hfc77800d;
            10'd522: reference_twiddle = 32'hfc138010;
            10'd523: reference_twiddle = 32'hfbae8014;
            10'd524: reference_twiddle = 32'hfb4a8017;
            10'd525: reference_twiddle = 32'hfae5801b;
            10'd526: reference_twiddle = 32'hfa81801f;
            10'd527: reference_twiddle = 32'hfa1d8024;
            10'd528: reference_twiddle = 32'hf9b88028;
            10'd529: reference_twiddle = 32'hf954802e;
            10'd530: reference_twiddle = 32'hf8ef8033;
            10'd531: reference_twiddle = 32'hf88b8039;
            10'd532: reference_twiddle = 32'hf827803f;
            10'd533: reference_twiddle = 32'hf7c28045;
            10'd534: reference_twiddle = 32'hf75e804c;
            10'd535: reference_twiddle = 32'hf6fa8053;
            10'd536: reference_twiddle = 32'hf696805a;
            10'd537: reference_twiddle = 32'hf6318061;
            10'd538: reference_twiddle = 32'hf5cd8069;
            10'd539: reference_twiddle = 32'hf5698071;
            10'd540: reference_twiddle = 32'hf505807a;
            10'd541: reference_twiddle = 32'hf4a18083;
            10'd542: reference_twiddle = 32'hf43c808c;
            10'd543: reference_twiddle = 32'hf3d88095;
            10'd544: reference_twiddle = 32'hf374809f;
            10'd545: reference_twiddle = 32'hf31080a9;
            10'd546: reference_twiddle = 32'hf2ac80b3;
            10'd547: reference_twiddle = 32'hf24880be;
            10'd548: reference_twiddle = 32'hf1e480c9;
            10'd549: reference_twiddle = 32'hf18080d4;
            10'd550: reference_twiddle = 32'hf11d80df;
            10'd551: reference_twiddle = 32'hf0b980eb;
            10'd552: reference_twiddle = 32'hf05580f7;
            10'd553: reference_twiddle = 32'heff18104;
            10'd554: reference_twiddle = 32'hef8e8111;
            10'd555: reference_twiddle = 32'hef2a811e;
            10'd556: reference_twiddle = 32'heec6812b;
            10'd557: reference_twiddle = 32'hee638139;
            10'd558: reference_twiddle = 32'hedff8147;
            10'd559: reference_twiddle = 32'hed9c8155;
            10'd560: reference_twiddle = 32'hed388164;
            10'd561: reference_twiddle = 32'hecd58173;
            10'd562: reference_twiddle = 32'hec718182;
            10'd563: reference_twiddle = 32'hec0e8191;
            10'd564: reference_twiddle = 32'hebab81a1;
            10'd565: reference_twiddle = 32'heb4781b1;
            10'd566: reference_twiddle = 32'heae481c2;
            10'd567: reference_twiddle = 32'hea8181d2;
            10'd568: reference_twiddle = 32'hea1e81e3;
            10'd569: reference_twiddle = 32'he9bb81f5;
            10'd570: reference_twiddle = 32'he9588206;
            10'd571: reference_twiddle = 32'he8f58218;
            10'd572: reference_twiddle = 32'he892822b;
            10'd573: reference_twiddle = 32'he830823d;
            10'd574: reference_twiddle = 32'he7cd8250;
            10'd575: reference_twiddle = 32'he76a8263;
            10'd576: reference_twiddle = 32'he7078277;
            10'd577: reference_twiddle = 32'he6a5828a;
            10'd578: reference_twiddle = 32'he642829e;
            10'd579: reference_twiddle = 32'he5e082b3;
            10'd580: reference_twiddle = 32'he57e82c7;
            10'd581: reference_twiddle = 32'he51b82dc;
            10'd582: reference_twiddle = 32'he4b982f2;
            10'd583: reference_twiddle = 32'he4578307;
            10'd584: reference_twiddle = 32'he3f5831d;
            10'd585: reference_twiddle = 32'he3938333;
            10'd586: reference_twiddle = 32'he331834a;
            10'd587: reference_twiddle = 32'he2cf8361;
            10'd588: reference_twiddle = 32'he26d8378;
            10'd589: reference_twiddle = 32'he20b838f;
            10'd590: reference_twiddle = 32'he1a983a7;
            10'd591: reference_twiddle = 32'he14883bf;
            10'd592: reference_twiddle = 32'he0e683d7;
            10'd593: reference_twiddle = 32'he08583f0;
            10'd594: reference_twiddle = 32'he0238408;
            10'd595: reference_twiddle = 32'hdfc28422;
            10'd596: reference_twiddle = 32'hdf61843b;
            10'd597: reference_twiddle = 32'hdf008455;
            10'd598: reference_twiddle = 32'hde9f846f;
            10'd599: reference_twiddle = 32'hde3e8489;
            10'd600: reference_twiddle = 32'hdddd84a4;
            10'd601: reference_twiddle = 32'hdd7c84bf;
            10'd602: reference_twiddle = 32'hdd1b84da;
            10'd603: reference_twiddle = 32'hdcba84f6;
            10'd604: reference_twiddle = 32'hdc5a8512;
            10'd605: reference_twiddle = 32'hdbf9852e;
            10'd606: reference_twiddle = 32'hdb99854a;
            10'd607: reference_twiddle = 32'hdb388567;
            10'd608: reference_twiddle = 32'hdad88584;
            10'd609: reference_twiddle = 32'hda7885a1;
            10'd610: reference_twiddle = 32'hda1885bf;
            10'd611: reference_twiddle = 32'hd9b885dd;
            10'd612: reference_twiddle = 32'hd95885fb;
            10'd613: reference_twiddle = 32'hd8f8861a;
            10'd614: reference_twiddle = 32'hd8998638;
            10'd615: reference_twiddle = 32'hd8398657;
            10'd616: reference_twiddle = 32'hd7da8677;
            10'd617: reference_twiddle = 32'hd77a8696;
            10'd618: reference_twiddle = 32'hd71b86b6;
            10'd619: reference_twiddle = 32'hd6bc86d7;
            10'd620: reference_twiddle = 32'hd65d86f7;
            10'd621: reference_twiddle = 32'hd5fe8718;
            10'd622: reference_twiddle = 32'hd59f8739;
            10'd623: reference_twiddle = 32'hd540875b;
            10'd624: reference_twiddle = 32'hd4e1877c;
            10'd625: reference_twiddle = 32'hd483879e;
            10'd626: reference_twiddle = 32'hd42487c1;
            10'd627: reference_twiddle = 32'hd3c687e3;
            10'd628: reference_twiddle = 32'hd3678806;
            10'd629: reference_twiddle = 32'hd3098829;
            10'd630: reference_twiddle = 32'hd2ab884d;
            10'd631: reference_twiddle = 32'hd24d8871;
            10'd632: reference_twiddle = 32'hd1ef8895;
            10'd633: reference_twiddle = 32'hd19288b9;
            10'd634: reference_twiddle = 32'hd13488de;
            10'd635: reference_twiddle = 32'hd0d68902;
            10'd636: reference_twiddle = 32'hd0798928;
            10'd637: reference_twiddle = 32'hd01c894d;
            10'd638: reference_twiddle = 32'hcfbf8973;
            10'd639: reference_twiddle = 32'hcf628999;
            10'd640: reference_twiddle = 32'hcf0589bf;
            10'd641: reference_twiddle = 32'hcea889e6;
            10'd642: reference_twiddle = 32'hce4b8a0d;
            10'd643: reference_twiddle = 32'hcdef8a34;
            10'd644: reference_twiddle = 32'hcd928a5b;
            10'd645: reference_twiddle = 32'hcd368a83;
            10'd646: reference_twiddle = 32'hccda8aab;
            10'd647: reference_twiddle = 32'hcc7d8ad3;
            10'd648: reference_twiddle = 32'hcc218afc;
            10'd649: reference_twiddle = 32'hcbc68b25;
            10'd650: reference_twiddle = 32'hcb6a8b4e;
            10'd651: reference_twiddle = 32'hcb0e8b78;
            10'd652: reference_twiddle = 32'hcab38ba1;
            10'd653: reference_twiddle = 32'hca588bcb;
            10'd654: reference_twiddle = 32'hc9fc8bf6;
            10'd655: reference_twiddle = 32'hc9a18c20;
            10'd656: reference_twiddle = 32'hc9468c4b;
            10'd657: reference_twiddle = 32'hc8eb8c76;
            10'd658: reference_twiddle = 32'hc8918ca2;
            10'd659: reference_twiddle = 32'hc8368ccd;
            10'd660: reference_twiddle = 32'hc7dc8cf9;
            10'd661: reference_twiddle = 32'hc7828d25;
            10'd662: reference_twiddle = 32'hc7278d52;
            10'd663: reference_twiddle = 32'hc6cd8d7f;
            10'd664: reference_twiddle = 32'hc6748dac;
            10'd665: reference_twiddle = 32'hc61a8dd9;
            10'd666: reference_twiddle = 32'hc5c08e07;
            10'd667: reference_twiddle = 32'hc5678e35;
            10'd668: reference_twiddle = 32'hc50e8e63;
            10'd669: reference_twiddle = 32'hc4b48e91;
            10'd670: reference_twiddle = 32'hc45b8ec0;
            10'd671: reference_twiddle = 32'hc4028eef;
            10'd672: reference_twiddle = 32'hc3aa8f1e;
            10'd673: reference_twiddle = 32'hc3518f4e;
            10'd674: reference_twiddle = 32'hc2f98f7d;
            10'd675: reference_twiddle = 32'hc2a08fad;
            10'd676: reference_twiddle = 32'hc2488fde;
            10'd677: reference_twiddle = 32'hc1f0900e;
            10'd678: reference_twiddle = 32'hc198903f;
            10'd679: reference_twiddle = 32'hc1419070;
            10'd680: reference_twiddle = 32'hc0e990a2;
            10'd681: reference_twiddle = 32'hc09290d4;
            10'd682: reference_twiddle = 32'hc03b9105;
            10'd683: reference_twiddle = 32'hbfe39138;
            10'd684: reference_twiddle = 32'hbf8d916a;
            10'd685: reference_twiddle = 32'hbf36919d;
            10'd686: reference_twiddle = 32'hbedf91d0;
            10'd687: reference_twiddle = 32'hbe899203;
            10'd688: reference_twiddle = 32'hbe329237;
            10'd689: reference_twiddle = 32'hbddc926b;
            10'd690: reference_twiddle = 32'hbd86929f;
            10'd691: reference_twiddle = 32'hbd3092d3;
            10'd692: reference_twiddle = 32'hbcdb9308;
            10'd693: reference_twiddle = 32'hbc85933d;
            10'd694: reference_twiddle = 32'hbc309372;
            10'd695: reference_twiddle = 32'hbbdb93a7;
            10'd696: reference_twiddle = 32'hbb8693dd;
            10'd697: reference_twiddle = 32'hbb319413;
            10'd698: reference_twiddle = 32'hbadc9449;
            10'd699: reference_twiddle = 32'hba88947f;
            10'd700: reference_twiddle = 32'hba3394b6;
            10'd701: reference_twiddle = 32'hb9df94ed;
            10'd702: reference_twiddle = 32'hb98b9524;
            10'd703: reference_twiddle = 32'hb937955c;
            10'd704: reference_twiddle = 32'hb8e49593;
            10'd705: reference_twiddle = 32'hb89095cb;
            10'd706: reference_twiddle = 32'hb83d9603;
            10'd707: reference_twiddle = 32'hb7ea963c;
            10'd708: reference_twiddle = 32'hb7979675;
            10'd709: reference_twiddle = 32'hb74496ae;
            10'd710: reference_twiddle = 32'hb6f196e7;
            10'd711: reference_twiddle = 32'hb69f9720;
            10'd712: reference_twiddle = 32'hb64c975a;
            10'd713: reference_twiddle = 32'hb5fa9794;
            10'd714: reference_twiddle = 32'hb5a897ce;
            10'd715: reference_twiddle = 32'hb5579809;
            10'd716: reference_twiddle = 32'hb5059844;
            10'd717: reference_twiddle = 32'hb4b4987f;
            10'd718: reference_twiddle = 32'hb46398ba;
            10'd719: reference_twiddle = 32'hb41298f6;
            10'd720: reference_twiddle = 32'hb3c19931;
            10'd721: reference_twiddle = 32'hb370996d;
            10'd722: reference_twiddle = 32'hb32099aa;
            10'd723: reference_twiddle = 32'hb2cf99e6;
            10'd724: reference_twiddle = 32'hb27f9a23;
            10'd725: reference_twiddle = 32'hb22f9a60;
            10'd726: reference_twiddle = 32'hb1e09a9d;
            10'd727: reference_twiddle = 32'hb1909adb;
            10'd728: reference_twiddle = 32'hb1419b18;
            10'd729: reference_twiddle = 32'hb0f29b56;
            10'd730: reference_twiddle = 32'hb0a39b94;
            10'd731: reference_twiddle = 32'hb0549bd3;
            10'd732: reference_twiddle = 32'hb0059c12;
            10'd733: reference_twiddle = 32'hafb79c51;
            10'd734: reference_twiddle = 32'haf699c90;
            10'd735: reference_twiddle = 32'haf1b9ccf;
            10'd736: reference_twiddle = 32'haecd9d0f;
            10'd737: reference_twiddle = 32'hae7f9d4f;
            10'd738: reference_twiddle = 32'hae329d8f;
            10'd739: reference_twiddle = 32'hade59dcf;
            10'd740: reference_twiddle = 32'had989e10;
            10'd741: reference_twiddle = 32'had4b9e51;
            10'd742: reference_twiddle = 32'hacfe9e92;
            10'd743: reference_twiddle = 32'hacb29ed3;
            10'd744: reference_twiddle = 32'hac659f15;
            10'd745: reference_twiddle = 32'hac199f56;
            10'd746: reference_twiddle = 32'habce9f98;
            10'd747: reference_twiddle = 32'hab829fdb;
            10'd748: reference_twiddle = 32'hab37a01d;
            10'd749: reference_twiddle = 32'haaeba060;
            10'd750: reference_twiddle = 32'haaa0a0a3;
            10'd751: reference_twiddle = 32'haa56a0e6;
            10'd752: reference_twiddle = 32'haa0ba129;
            10'd753: reference_twiddle = 32'ha9c1a16d;
            10'd754: reference_twiddle = 32'ha976a1b1;
            10'd755: reference_twiddle = 32'ha92da1f5;
            10'd756: reference_twiddle = 32'ha8e3a239;
            10'd757: reference_twiddle = 32'ha899a27e;
            10'd758: reference_twiddle = 32'ha850a2c2;
            10'd759: reference_twiddle = 32'ha807a307;
            10'd760: reference_twiddle = 32'ha7bea34d;
            10'd761: reference_twiddle = 32'ha775a392;
            10'd762: reference_twiddle = 32'ha72da3d8;
            10'd763: reference_twiddle = 32'ha6e4a41e;
            10'd764: reference_twiddle = 32'ha69ca464;
            10'd765: reference_twiddle = 32'ha654a4aa;
            10'd766: reference_twiddle = 32'ha60da4f1;
            10'd767: reference_twiddle = 32'ha5c5a537;
            10'd768: reference_twiddle = 32'ha57ea57e;
            10'd769: reference_twiddle = 32'ha537a5c5;
            10'd770: reference_twiddle = 32'ha4f1a60d;
            10'd771: reference_twiddle = 32'ha4aaa654;
            10'd772: reference_twiddle = 32'ha464a69c;
            10'd773: reference_twiddle = 32'ha41ea6e4;
            10'd774: reference_twiddle = 32'ha3d8a72d;
            10'd775: reference_twiddle = 32'ha392a775;
            10'd776: reference_twiddle = 32'ha34da7be;
            10'd777: reference_twiddle = 32'ha307a807;
            10'd778: reference_twiddle = 32'ha2c2a850;
            10'd779: reference_twiddle = 32'ha27ea899;
            10'd780: reference_twiddle = 32'ha239a8e3;
            10'd781: reference_twiddle = 32'ha1f5a92d;
            10'd782: reference_twiddle = 32'ha1b1a976;
            10'd783: reference_twiddle = 32'ha16da9c1;
            10'd784: reference_twiddle = 32'ha129aa0b;
            10'd785: reference_twiddle = 32'ha0e6aa56;
            10'd786: reference_twiddle = 32'ha0a3aaa0;
            10'd787: reference_twiddle = 32'ha060aaeb;
            10'd788: reference_twiddle = 32'ha01dab37;
            10'd789: reference_twiddle = 32'h9fdbab82;
            10'd790: reference_twiddle = 32'h9f98abce;
            10'd791: reference_twiddle = 32'h9f56ac19;
            10'd792: reference_twiddle = 32'h9f15ac65;
            10'd793: reference_twiddle = 32'h9ed3acb2;
            10'd794: reference_twiddle = 32'h9e92acfe;
            10'd795: reference_twiddle = 32'h9e51ad4b;
            10'd796: reference_twiddle = 32'h9e10ad98;
            10'd797: reference_twiddle = 32'h9dcfade5;
            10'd798: reference_twiddle = 32'h9d8fae32;
            10'd799: reference_twiddle = 32'h9d4fae7f;
            10'd800: reference_twiddle = 32'h9d0faecd;
            10'd801: reference_twiddle = 32'h9ccfaf1b;
            10'd802: reference_twiddle = 32'h9c90af69;
            10'd803: reference_twiddle = 32'h9c51afb7;
            10'd804: reference_twiddle = 32'h9c12b005;
            10'd805: reference_twiddle = 32'h9bd3b054;
            10'd806: reference_twiddle = 32'h9b94b0a3;
            10'd807: reference_twiddle = 32'h9b56b0f2;
            10'd808: reference_twiddle = 32'h9b18b141;
            10'd809: reference_twiddle = 32'h9adbb190;
            10'd810: reference_twiddle = 32'h9a9db1e0;
            10'd811: reference_twiddle = 32'h9a60b22f;
            10'd812: reference_twiddle = 32'h9a23b27f;
            10'd813: reference_twiddle = 32'h99e6b2cf;
            10'd814: reference_twiddle = 32'h99aab320;
            10'd815: reference_twiddle = 32'h996db370;
            10'd816: reference_twiddle = 32'h9931b3c1;
            10'd817: reference_twiddle = 32'h98f6b412;
            10'd818: reference_twiddle = 32'h98bab463;
            10'd819: reference_twiddle = 32'h987fb4b4;
            10'd820: reference_twiddle = 32'h9844b505;
            10'd821: reference_twiddle = 32'h9809b557;
            10'd822: reference_twiddle = 32'h97ceb5a8;
            10'd823: reference_twiddle = 32'h9794b5fa;
            10'd824: reference_twiddle = 32'h975ab64c;
            10'd825: reference_twiddle = 32'h9720b69f;
            10'd826: reference_twiddle = 32'h96e7b6f1;
            10'd827: reference_twiddle = 32'h96aeb744;
            10'd828: reference_twiddle = 32'h9675b797;
            10'd829: reference_twiddle = 32'h963cb7ea;
            10'd830: reference_twiddle = 32'h9603b83d;
            10'd831: reference_twiddle = 32'h95cbb890;
            10'd832: reference_twiddle = 32'h9593b8e4;
            10'd833: reference_twiddle = 32'h955cb937;
            10'd834: reference_twiddle = 32'h9524b98b;
            10'd835: reference_twiddle = 32'h94edb9df;
            10'd836: reference_twiddle = 32'h94b6ba33;
            10'd837: reference_twiddle = 32'h947fba88;
            10'd838: reference_twiddle = 32'h9449badc;
            10'd839: reference_twiddle = 32'h9413bb31;
            10'd840: reference_twiddle = 32'h93ddbb86;
            10'd841: reference_twiddle = 32'h93a7bbdb;
            10'd842: reference_twiddle = 32'h9372bc30;
            10'd843: reference_twiddle = 32'h933dbc85;
            10'd844: reference_twiddle = 32'h9308bcdb;
            10'd845: reference_twiddle = 32'h92d3bd30;
            10'd846: reference_twiddle = 32'h929fbd86;
            10'd847: reference_twiddle = 32'h926bbddc;
            10'd848: reference_twiddle = 32'h9237be32;
            10'd849: reference_twiddle = 32'h9203be89;
            10'd850: reference_twiddle = 32'h91d0bedf;
            10'd851: reference_twiddle = 32'h919dbf36;
            10'd852: reference_twiddle = 32'h916abf8d;
            10'd853: reference_twiddle = 32'h9138bfe3;
            10'd854: reference_twiddle = 32'h9105c03b;
            10'd855: reference_twiddle = 32'h90d4c092;
            10'd856: reference_twiddle = 32'h90a2c0e9;
            10'd857: reference_twiddle = 32'h9070c141;
            10'd858: reference_twiddle = 32'h903fc198;
            10'd859: reference_twiddle = 32'h900ec1f0;
            10'd860: reference_twiddle = 32'h8fdec248;
            10'd861: reference_twiddle = 32'h8fadc2a0;
            10'd862: reference_twiddle = 32'h8f7dc2f9;
            10'd863: reference_twiddle = 32'h8f4ec351;
            10'd864: reference_twiddle = 32'h8f1ec3aa;
            10'd865: reference_twiddle = 32'h8eefc402;
            10'd866: reference_twiddle = 32'h8ec0c45b;
            10'd867: reference_twiddle = 32'h8e91c4b4;
            10'd868: reference_twiddle = 32'h8e63c50e;
            10'd869: reference_twiddle = 32'h8e35c567;
            10'd870: reference_twiddle = 32'h8e07c5c0;
            10'd871: reference_twiddle = 32'h8dd9c61a;
            10'd872: reference_twiddle = 32'h8dacc674;
            10'd873: reference_twiddle = 32'h8d7fc6cd;
            10'd874: reference_twiddle = 32'h8d52c727;
            10'd875: reference_twiddle = 32'h8d25c782;
            10'd876: reference_twiddle = 32'h8cf9c7dc;
            10'd877: reference_twiddle = 32'h8ccdc836;
            10'd878: reference_twiddle = 32'h8ca2c891;
            10'd879: reference_twiddle = 32'h8c76c8eb;
            10'd880: reference_twiddle = 32'h8c4bc946;
            10'd881: reference_twiddle = 32'h8c20c9a1;
            10'd882: reference_twiddle = 32'h8bf6c9fc;
            10'd883: reference_twiddle = 32'h8bcbca58;
            10'd884: reference_twiddle = 32'h8ba1cab3;
            10'd885: reference_twiddle = 32'h8b78cb0e;
            10'd886: reference_twiddle = 32'h8b4ecb6a;
            10'd887: reference_twiddle = 32'h8b25cbc6;
            10'd888: reference_twiddle = 32'h8afccc21;
            10'd889: reference_twiddle = 32'h8ad3cc7d;
            10'd890: reference_twiddle = 32'h8aabccda;
            10'd891: reference_twiddle = 32'h8a83cd36;
            10'd892: reference_twiddle = 32'h8a5bcd92;
            10'd893: reference_twiddle = 32'h8a34cdef;
            10'd894: reference_twiddle = 32'h8a0dce4b;
            10'd895: reference_twiddle = 32'h89e6cea8;
            10'd896: reference_twiddle = 32'h89bfcf05;
            10'd897: reference_twiddle = 32'h8999cf62;
            10'd898: reference_twiddle = 32'h8973cfbf;
            10'd899: reference_twiddle = 32'h894dd01c;
            10'd900: reference_twiddle = 32'h8928d079;
            10'd901: reference_twiddle = 32'h8902d0d6;
            10'd902: reference_twiddle = 32'h88ded134;
            10'd903: reference_twiddle = 32'h88b9d192;
            10'd904: reference_twiddle = 32'h8895d1ef;
            10'd905: reference_twiddle = 32'h8871d24d;
            10'd906: reference_twiddle = 32'h884dd2ab;
            10'd907: reference_twiddle = 32'h8829d309;
            10'd908: reference_twiddle = 32'h8806d367;
            10'd909: reference_twiddle = 32'h87e3d3c6;
            10'd910: reference_twiddle = 32'h87c1d424;
            10'd911: reference_twiddle = 32'h879ed483;
            10'd912: reference_twiddle = 32'h877cd4e1;
            10'd913: reference_twiddle = 32'h875bd540;
            10'd914: reference_twiddle = 32'h8739d59f;
            10'd915: reference_twiddle = 32'h8718d5fe;
            10'd916: reference_twiddle = 32'h86f7d65d;
            10'd917: reference_twiddle = 32'h86d7d6bc;
            10'd918: reference_twiddle = 32'h86b6d71b;
            10'd919: reference_twiddle = 32'h8696d77a;
            10'd920: reference_twiddle = 32'h8677d7da;
            10'd921: reference_twiddle = 32'h8657d839;
            10'd922: reference_twiddle = 32'h8638d899;
            10'd923: reference_twiddle = 32'h861ad8f8;
            10'd924: reference_twiddle = 32'h85fbd958;
            10'd925: reference_twiddle = 32'h85ddd9b8;
            10'd926: reference_twiddle = 32'h85bfda18;
            10'd927: reference_twiddle = 32'h85a1da78;
            10'd928: reference_twiddle = 32'h8584dad8;
            10'd929: reference_twiddle = 32'h8567db38;
            10'd930: reference_twiddle = 32'h854adb99;
            10'd931: reference_twiddle = 32'h852edbf9;
            10'd932: reference_twiddle = 32'h8512dc5a;
            10'd933: reference_twiddle = 32'h84f6dcba;
            10'd934: reference_twiddle = 32'h84dadd1b;
            10'd935: reference_twiddle = 32'h84bfdd7c;
            10'd936: reference_twiddle = 32'h84a4dddd;
            10'd937: reference_twiddle = 32'h8489de3e;
            10'd938: reference_twiddle = 32'h846fde9f;
            10'd939: reference_twiddle = 32'h8455df00;
            10'd940: reference_twiddle = 32'h843bdf61;
            10'd941: reference_twiddle = 32'h8422dfc2;
            10'd942: reference_twiddle = 32'h8408e023;
            10'd943: reference_twiddle = 32'h83f0e085;
            10'd944: reference_twiddle = 32'h83d7e0e6;
            10'd945: reference_twiddle = 32'h83bfe148;
            10'd946: reference_twiddle = 32'h83a7e1a9;
            10'd947: reference_twiddle = 32'h838fe20b;
            10'd948: reference_twiddle = 32'h8378e26d;
            10'd949: reference_twiddle = 32'h8361e2cf;
            10'd950: reference_twiddle = 32'h834ae331;
            10'd951: reference_twiddle = 32'h8333e393;
            10'd952: reference_twiddle = 32'h831de3f5;
            10'd953: reference_twiddle = 32'h8307e457;
            10'd954: reference_twiddle = 32'h82f2e4b9;
            10'd955: reference_twiddle = 32'h82dce51b;
            10'd956: reference_twiddle = 32'h82c7e57e;
            10'd957: reference_twiddle = 32'h82b3e5e0;
            10'd958: reference_twiddle = 32'h829ee642;
            10'd959: reference_twiddle = 32'h828ae6a5;
            10'd960: reference_twiddle = 32'h8277e707;
            10'd961: reference_twiddle = 32'h8263e76a;
            10'd962: reference_twiddle = 32'h8250e7cd;
            10'd963: reference_twiddle = 32'h823de830;
            10'd964: reference_twiddle = 32'h822be892;
            10'd965: reference_twiddle = 32'h8218e8f5;
            10'd966: reference_twiddle = 32'h8206e958;
            10'd967: reference_twiddle = 32'h81f5e9bb;
            10'd968: reference_twiddle = 32'h81e3ea1e;
            10'd969: reference_twiddle = 32'h81d2ea81;
            10'd970: reference_twiddle = 32'h81c2eae4;
            10'd971: reference_twiddle = 32'h81b1eb47;
            10'd972: reference_twiddle = 32'h81a1ebab;
            10'd973: reference_twiddle = 32'h8191ec0e;
            10'd974: reference_twiddle = 32'h8182ec71;
            10'd975: reference_twiddle = 32'h8173ecd5;
            10'd976: reference_twiddle = 32'h8164ed38;
            10'd977: reference_twiddle = 32'h8155ed9c;
            10'd978: reference_twiddle = 32'h8147edff;
            10'd979: reference_twiddle = 32'h8139ee63;
            10'd980: reference_twiddle = 32'h812beec6;
            10'd981: reference_twiddle = 32'h811eef2a;
            10'd982: reference_twiddle = 32'h8111ef8e;
            10'd983: reference_twiddle = 32'h8104eff1;
            10'd984: reference_twiddle = 32'h80f7f055;
            10'd985: reference_twiddle = 32'h80ebf0b9;
            10'd986: reference_twiddle = 32'h80dff11d;
            10'd987: reference_twiddle = 32'h80d4f180;
            10'd988: reference_twiddle = 32'h80c9f1e4;
            10'd989: reference_twiddle = 32'h80bef248;
            10'd990: reference_twiddle = 32'h80b3f2ac;
            10'd991: reference_twiddle = 32'h80a9f310;
            10'd992: reference_twiddle = 32'h809ff374;
            10'd993: reference_twiddle = 32'h8095f3d8;
            10'd994: reference_twiddle = 32'h808cf43c;
            10'd995: reference_twiddle = 32'h8083f4a1;
            10'd996: reference_twiddle = 32'h807af505;
            10'd997: reference_twiddle = 32'h8071f569;
            10'd998: reference_twiddle = 32'h8069f5cd;
            10'd999: reference_twiddle = 32'h8061f631;
            10'd1000: reference_twiddle = 32'h805af696;
            10'd1001: reference_twiddle = 32'h8053f6fa;
            10'd1002: reference_twiddle = 32'h804cf75e;
            10'd1003: reference_twiddle = 32'h8045f7c2;
            10'd1004: reference_twiddle = 32'h803ff827;
            10'd1005: reference_twiddle = 32'h8039f88b;
            10'd1006: reference_twiddle = 32'h8033f8ef;
            10'd1007: reference_twiddle = 32'h802ef954;
            10'd1008: reference_twiddle = 32'h8028f9b8;
            10'd1009: reference_twiddle = 32'h8024fa1d;
            10'd1010: reference_twiddle = 32'h801ffa81;
            10'd1011: reference_twiddle = 32'h801bfae5;
            10'd1012: reference_twiddle = 32'h8017fb4a;
            10'd1013: reference_twiddle = 32'h8014fbae;
            10'd1014: reference_twiddle = 32'h8010fc13;
            10'd1015: reference_twiddle = 32'h800dfc77;
            10'd1016: reference_twiddle = 32'h800bfcdc;
            10'd1017: reference_twiddle = 32'h8009fd40;
            10'd1018: reference_twiddle = 32'h8007fda5;
            10'd1019: reference_twiddle = 32'h8005fe09;
            10'd1020: reference_twiddle = 32'h8003fe6e;
            10'd1021: reference_twiddle = 32'h8002fed2;
            10'd1022: reference_twiddle = 32'h8002ff37;
            10'd1023: reference_twiddle = 32'h8001ff9b;
            default: reference_twiddle = 32'h7fff0000;
        endcase
    end
endfunction
function [16:0] reference_position;
    input [6:0] index;
    begin
        reference_position[0] = (80'hfb19812836ce4a002e58 >> index) & 1'b1;
        reference_position[1] = (80'h1bd82ee4f2fc466fc2f2 >> index) & 1'b1;
        reference_position[2] = (80'h2f1301c0abd4ab033a74 >> index) & 1'b1;
        reference_position[3] = (80'h52ec31ebcacc8091edd8 >> index) & 1'b1;
        reference_position[4] = (80'h4dbd12010ea5445f4fca >> index) & 1'b1;
        reference_position[5] = (80'hb18cc15c6a14829f256c >> index) & 1'b1;
        reference_position[6] = (80'h3413ec0dc8f101b5b670 >> index) & 1'b1;
        reference_position[7] = (80'he6933886230caad9c780 >> index) & 1'b1;
        reference_position[8] = (80'h7401efa81956cce1f800 >> index) & 1'b1;
        reference_position[9] = (80'h305f4f9aad98f0fe0000 >> index) & 1'b1;
        reference_position[10] = (80'h4d60dad331e0ff000000 >> index) & 1'b1;
        reference_position[11] = (80'h7cd56ce3c1ff00000000 >> index) & 1'b1;
        reference_position[12] = (80'hd6998f03fe0000000000 >> index) & 1'b1;
        reference_position[13] = (80'h671e0ffc000000000000 >> index) & 1'b1;
        reference_position[14] = (80'h781ff000000000000000 >> index) & 1'b1;
        reference_position[15] = (80'h7fe00000000000000000 >> index) & 1'b1;
        reference_position[16] = (80'h80000000000000000000 >> index) & 1'b1;
    end
endfunction
function [7:0] reference_log_fraction;
    input [5:0] index;
    begin
        case (index)
            6'd0: reference_log_fraction = 8'd0;
            6'd1: reference_log_fraction = 8'd2;
            6'd2: reference_log_fraction = 8'd3;
            6'd3: reference_log_fraction = 8'd5;
            6'd4: reference_log_fraction = 8'd6;
            6'd5: reference_log_fraction = 8'd8;
            6'd6: reference_log_fraction = 8'd9;
            6'd7: reference_log_fraction = 8'd10;
            6'd8: reference_log_fraction = 8'd12;
            6'd9: reference_log_fraction = 8'd13;
            6'd10: reference_log_fraction = 8'd15;
            6'd11: reference_log_fraction = 8'd16;
            6'd12: reference_log_fraction = 8'd17;
            6'd13: reference_log_fraction = 8'd18;
            6'd14: reference_log_fraction = 8'd20;
            6'd15: reference_log_fraction = 8'd21;
            6'd16: reference_log_fraction = 8'd22;
            6'd17: reference_log_fraction = 8'd24;
            6'd18: reference_log_fraction = 8'd25;
            6'd19: reference_log_fraction = 8'd26;
            6'd20: reference_log_fraction = 8'd27;
            6'd21: reference_log_fraction = 8'd28;
            6'd22: reference_log_fraction = 8'd30;
            6'd23: reference_log_fraction = 8'd31;
            6'd24: reference_log_fraction = 8'd32;
            6'd25: reference_log_fraction = 8'd33;
            6'd26: reference_log_fraction = 8'd34;
            6'd27: reference_log_fraction = 8'd35;
            6'd28: reference_log_fraction = 8'd36;
            6'd29: reference_log_fraction = 8'd37;
            6'd30: reference_log_fraction = 8'd38;
            6'd31: reference_log_fraction = 8'd39;
            6'd32: reference_log_fraction = 8'd41;
            6'd33: reference_log_fraction = 8'd42;
            6'd34: reference_log_fraction = 8'd43;
            6'd35: reference_log_fraction = 8'd44;
            6'd36: reference_log_fraction = 8'd45;
            6'd37: reference_log_fraction = 8'd46;
            6'd38: reference_log_fraction = 8'd47;
            6'd39: reference_log_fraction = 8'd48;
            6'd40: reference_log_fraction = 8'd49;
            6'd41: reference_log_fraction = 8'd50;
            6'd42: reference_log_fraction = 8'd50;
            6'd43: reference_log_fraction = 8'd51;
            6'd44: reference_log_fraction = 8'd52;
            6'd45: reference_log_fraction = 8'd53;
            6'd46: reference_log_fraction = 8'd54;
            6'd47: reference_log_fraction = 8'd55;
            6'd48: reference_log_fraction = 8'd56;
            6'd49: reference_log_fraction = 8'd57;
            6'd50: reference_log_fraction = 8'd58;
            6'd51: reference_log_fraction = 8'd59;
            6'd52: reference_log_fraction = 8'd59;
            6'd53: reference_log_fraction = 8'd60;
            6'd54: reference_log_fraction = 8'd61;
            6'd55: reference_log_fraction = 8'd62;
            6'd56: reference_log_fraction = 8'd63;
            6'd57: reference_log_fraction = 8'd64;
            6'd58: reference_log_fraction = 8'd65;
            6'd59: reference_log_fraction = 8'd65;
            6'd60: reference_log_fraction = 8'd66;
            6'd61: reference_log_fraction = 8'd67;
            6'd62: reference_log_fraction = 8'd68;
            6'd63: reference_log_fraction = 8'd69;
            default: reference_log_fraction = 8'd0;
        endcase
    end
endfunction
// END REFERENCE TABLES
wire bank0_we = (capture_we && !capture_bank) || (process_we && !process_bank);
wire bank1_we = (capture_we && capture_bank) || (process_we && process_bank);
wire [ADDR_W-1:0] bank0_addr = (process_we && !process_bank) ? write_addr : capture_addr;
wire [ADDR_W-1:0] bank1_addr = (process_we && process_bank) ? write_addr : capture_addr;
wire [31:0] bank0_data = (process_we && !process_bank) ? write_data :
                         {windowed_pcm,16'd0};
wire [31:0] bank1_data = (process_we && process_bank) ? write_data :
                         {windowed_pcm,16'd0};

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
    if(rst) begin
        state<=ST_INIT;scan_bin<=0;sample_count<=0;capture_bank<=0;process_bank<=0;
        group_base<=0;pair_index<=0;step<=1;stage<=0;
        bars<=0;bars_build<=0;pending_valid<=0;frame_start_d<=0;
        breath_radius<=8'd90;radius_build<=8'd90;raw_peak<=0;peak_envelope<=0;
        bar_index<=0;sqrt_count<=0;sqrt_root<=0;sqrt_remainder<=0;square_sum<=0;
        a_data<=0;b_data<=0;twiddle_word<=0;p0<=0;p1<=0;p2<=0;p3<=0;
        result_a<=0;result_b<=0;magnitude_a<=0;magnitude_b<=0;
        interpolated_product<=0;bar_level<=0;
    end else begin
        frame_start_d<=frame_start;
        // build 只在完整生成 80 柱后有效；开始下一次构建时撤销有效标志。
        // 避免使用第三组 640 位寄存器，也不会发布正在改写的半帧数据。
        if(frame_start && !frame_start_d && pending_valid) begin
            bars<=bars_build;breath_radius<=radius_build;pending_valid<=0;
        end
        if(capture_we) begin
            if(sample_count==FFT_POINTS-1) begin
                sample_count<=0;
                if(state==ST_IDLE) begin
                    process_bank<=capture_bank;capture_bank<=~capture_bank;
                    group_base<=0;pair_index<=0;step<=1;stage<=0;state<=ST_RD_A;
                end
            end else sample_count<=sample_count+1'b1;
        end
        case(state)
            ST_INIT: if(scan_bin==LAST_BIN) begin scan_bin<=0;state<=ST_IDLE;end
                     else scan_bin<=scan_bin+1'b1;
            ST_IDLE: begin end
            ST_RD_A: state<=ST_LATCH_A;
            ST_LATCH_A: begin a_data<=read_data;state<=ST_RD_B;end
            ST_RD_B: state<=ST_LATCH_B;
            ST_LATCH_B: begin b_data<=read_data;twiddle_word<=reference_twiddle(twiddle_index);state<=ST_M0;end
            ST_M0: begin p0<=product;state<=ST_M1;end
            ST_M1: begin p1<=product;state<=ST_M2;end
            ST_M2: begin p2<=product;state<=ST_M3;end
            ST_M3: begin p3<=product;state<=ST_CALC;end
            ST_CALC: begin
                result_a<={sat16((ar+rotated_real)>>>1),sat16((ai+rotated_imag)>>>1)};
                result_b<={sat16((ar-rotated_real)>>>1),sat16((ai-rotated_imag)>>>1)};
                state<=ST_WR_A;
            end
            ST_WR_A: state<=ST_WR_B;
            ST_WR_B: begin
                if(pair_index+1'b1<step) pair_index<=pair_index+1'b1;
                else begin
                    pair_index<=0;
                    if({1'b0,group_base}+{step,1'b0}<FFT_POINTS) group_base<=group_base+(step<<1);
                    else begin
                        group_base<=0;step<=step<<1;stage<=stage+1'b1;
                        if(stage==ADDR_W-1) begin scan_bin<=0;raw_peak<=0;state<=ST_SCAN_RD;end
                    end
                end
                if(stage!=ADDR_W-1 || pair_index+1'b1<step || {1'b0,group_base}+{step,1'b0}<FFT_POINTS) state<=ST_RD_A;
            end
            ST_SCAN_RD: state<=ST_SCAN_EVAL;
            ST_SCAN_EVAL: begin square_sum<=product;b_data<=read_data;state<=ST_SQUARE_I;end
            ST_SQUARE_I: begin
                square_sum<=square_sum+product;sqrt_remainder<=0;sqrt_root<=0;sqrt_count<=0;state<=ST_SQRT;
            end
            ST_SQRT: begin
                sqrt_remainder<=sqrt_accept?(sqrt_shift-sqrt_trial):sqrt_shift;
                sqrt_root<={sqrt_root[14:0],sqrt_accept};square_sum<=square_sum<<2;
                sqrt_count<=sqrt_count+1'b1;
                if(sqrt_count==15) state<=ST_MAG_WRITE;
            end
            ST_MAG_WRITE: begin
                if(raw_m_q8>raw_peak) raw_peak<=raw_m_q8;
                // 音柱仅保存显示范围；呼吸峰值必须扫描完整正频率，含 Nyquist。
                if(scan_bin==FFT_POINTS/2) begin bar_index<=0;pending_valid<=0;state<=ST_BAR_RD_A;end
                else begin scan_bin<=scan_bin+1'b1;state<=ST_SCAN_RD;end
            end
            ST_BAR_RD_A: state<=ST_BAR_A;
            ST_BAR_A: begin magnitude_a<=history_q[18:0];state<=ST_BAR_RD_B;end
            ST_BAR_RD_B: state<=ST_BAR_B;
            ST_BAR_B: begin magnitude_b<=history_q[18:0];state<=ST_BLEND;end
            ST_BLEND: begin
                // 幅度先线性插值，再对数压缩，避免先压缩后插值产生错误轮廓。
                interpolated_product<=magnitude_a*(9'd256-{1'b0,fraction})+magnitude_b*fraction;
                state<=ST_LOG;
            end
            ST_LOG: begin bar_level<=reference_level(log_argument);state<=ST_BAR_WRITE;end
            ST_BAR_WRITE: begin
                bars_build[bar_index*8 +:8]<=bar_level;
                if(bar_index==79) begin
                    peak_envelope<=next_envelope;
                    radius_build<=8'd90+{3'd0,radius_offset(next_envelope)};
                    pending_valid<=1;state<=ST_IDLE;
                end else begin bar_index<=bar_index+1'b1;state<=ST_BAR_RD_A;end
            end
            default: state<=ST_INIT;
        endcase
    end
end
endmodule
