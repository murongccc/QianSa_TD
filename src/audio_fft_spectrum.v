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
// 由 generate_reference_fft_tables.py 生成；同步块 ROM 不依赖外部初始化文件。
(* rom_style="bram" *) reg [31:0] twiddle_memory [0:1023];
initial begin
    twiddle_memory[0] = 32'h7fff0000;
    twiddle_memory[1] = 32'h7fffff9b;
    twiddle_memory[2] = 32'h7ffeff37;
    twiddle_memory[3] = 32'h7ffefed2;
    twiddle_memory[4] = 32'h7ffdfe6e;
    twiddle_memory[5] = 32'h7ffbfe09;
    twiddle_memory[6] = 32'h7ff9fda5;
    twiddle_memory[7] = 32'h7ff7fd40;
    twiddle_memory[8] = 32'h7ff5fcdc;
    twiddle_memory[9] = 32'h7ff3fc77;
    twiddle_memory[10] = 32'h7ff0fc13;
    twiddle_memory[11] = 32'h7fecfbae;
    twiddle_memory[12] = 32'h7fe9fb4a;
    twiddle_memory[13] = 32'h7fe5fae5;
    twiddle_memory[14] = 32'h7fe1fa81;
    twiddle_memory[15] = 32'h7fdcfa1d;
    twiddle_memory[16] = 32'h7fd8f9b8;
    twiddle_memory[17] = 32'h7fd2f954;
    twiddle_memory[18] = 32'h7fcdf8ef;
    twiddle_memory[19] = 32'h7fc7f88b;
    twiddle_memory[20] = 32'h7fc1f827;
    twiddle_memory[21] = 32'h7fbbf7c2;
    twiddle_memory[22] = 32'h7fb4f75e;
    twiddle_memory[23] = 32'h7fadf6fa;
    twiddle_memory[24] = 32'h7fa6f696;
    twiddle_memory[25] = 32'h7f9ff631;
    twiddle_memory[26] = 32'h7f97f5cd;
    twiddle_memory[27] = 32'h7f8ff569;
    twiddle_memory[28] = 32'h7f86f505;
    twiddle_memory[29] = 32'h7f7df4a1;
    twiddle_memory[30] = 32'h7f74f43c;
    twiddle_memory[31] = 32'h7f6bf3d8;
    twiddle_memory[32] = 32'h7f61f374;
    twiddle_memory[33] = 32'h7f57f310;
    twiddle_memory[34] = 32'h7f4df2ac;
    twiddle_memory[35] = 32'h7f42f248;
    twiddle_memory[36] = 32'h7f37f1e4;
    twiddle_memory[37] = 32'h7f2cf180;
    twiddle_memory[38] = 32'h7f21f11d;
    twiddle_memory[39] = 32'h7f15f0b9;
    twiddle_memory[40] = 32'h7f09f055;
    twiddle_memory[41] = 32'h7efceff1;
    twiddle_memory[42] = 32'h7eefef8e;
    twiddle_memory[43] = 32'h7ee2ef2a;
    twiddle_memory[44] = 32'h7ed5eec6;
    twiddle_memory[45] = 32'h7ec7ee63;
    twiddle_memory[46] = 32'h7eb9edff;
    twiddle_memory[47] = 32'h7eabed9c;
    twiddle_memory[48] = 32'h7e9ced38;
    twiddle_memory[49] = 32'h7e8decd5;
    twiddle_memory[50] = 32'h7e7eec71;
    twiddle_memory[51] = 32'h7e6fec0e;
    twiddle_memory[52] = 32'h7e5febab;
    twiddle_memory[53] = 32'h7e4feb47;
    twiddle_memory[54] = 32'h7e3eeae4;
    twiddle_memory[55] = 32'h7e2eea81;
    twiddle_memory[56] = 32'h7e1dea1e;
    twiddle_memory[57] = 32'h7e0be9bb;
    twiddle_memory[58] = 32'h7dfae958;
    twiddle_memory[59] = 32'h7de8e8f5;
    twiddle_memory[60] = 32'h7dd5e892;
    twiddle_memory[61] = 32'h7dc3e830;
    twiddle_memory[62] = 32'h7db0e7cd;
    twiddle_memory[63] = 32'h7d9de76a;
    twiddle_memory[64] = 32'h7d89e707;
    twiddle_memory[65] = 32'h7d76e6a5;
    twiddle_memory[66] = 32'h7d62e642;
    twiddle_memory[67] = 32'h7d4de5e0;
    twiddle_memory[68] = 32'h7d39e57e;
    twiddle_memory[69] = 32'h7d24e51b;
    twiddle_memory[70] = 32'h7d0ee4b9;
    twiddle_memory[71] = 32'h7cf9e457;
    twiddle_memory[72] = 32'h7ce3e3f5;
    twiddle_memory[73] = 32'h7ccde393;
    twiddle_memory[74] = 32'h7cb6e331;
    twiddle_memory[75] = 32'h7c9fe2cf;
    twiddle_memory[76] = 32'h7c88e26d;
    twiddle_memory[77] = 32'h7c71e20b;
    twiddle_memory[78] = 32'h7c59e1a9;
    twiddle_memory[79] = 32'h7c41e148;
    twiddle_memory[80] = 32'h7c29e0e6;
    twiddle_memory[81] = 32'h7c10e085;
    twiddle_memory[82] = 32'h7bf8e023;
    twiddle_memory[83] = 32'h7bdedfc2;
    twiddle_memory[84] = 32'h7bc5df61;
    twiddle_memory[85] = 32'h7babdf00;
    twiddle_memory[86] = 32'h7b91de9f;
    twiddle_memory[87] = 32'h7b77de3e;
    twiddle_memory[88] = 32'h7b5cdddd;
    twiddle_memory[89] = 32'h7b41dd7c;
    twiddle_memory[90] = 32'h7b26dd1b;
    twiddle_memory[91] = 32'h7b0adcba;
    twiddle_memory[92] = 32'h7aeedc5a;
    twiddle_memory[93] = 32'h7ad2dbf9;
    twiddle_memory[94] = 32'h7ab6db99;
    twiddle_memory[95] = 32'h7a99db38;
    twiddle_memory[96] = 32'h7a7cdad8;
    twiddle_memory[97] = 32'h7a5fda78;
    twiddle_memory[98] = 32'h7a41da18;
    twiddle_memory[99] = 32'h7a23d9b8;
    twiddle_memory[100] = 32'h7a05d958;
    twiddle_memory[101] = 32'h79e6d8f8;
    twiddle_memory[102] = 32'h79c8d899;
    twiddle_memory[103] = 32'h79a9d839;
    twiddle_memory[104] = 32'h7989d7da;
    twiddle_memory[105] = 32'h796ad77a;
    twiddle_memory[106] = 32'h794ad71b;
    twiddle_memory[107] = 32'h7929d6bc;
    twiddle_memory[108] = 32'h7909d65d;
    twiddle_memory[109] = 32'h78e8d5fe;
    twiddle_memory[110] = 32'h78c7d59f;
    twiddle_memory[111] = 32'h78a5d540;
    twiddle_memory[112] = 32'h7884d4e1;
    twiddle_memory[113] = 32'h7862d483;
    twiddle_memory[114] = 32'h783fd424;
    twiddle_memory[115] = 32'h781dd3c6;
    twiddle_memory[116] = 32'h77fad367;
    twiddle_memory[117] = 32'h77d7d309;
    twiddle_memory[118] = 32'h77b3d2ab;
    twiddle_memory[119] = 32'h778fd24d;
    twiddle_memory[120] = 32'h776bd1ef;
    twiddle_memory[121] = 32'h7747d192;
    twiddle_memory[122] = 32'h7722d134;
    twiddle_memory[123] = 32'h76fed0d6;
    twiddle_memory[124] = 32'h76d8d079;
    twiddle_memory[125] = 32'h76b3d01c;
    twiddle_memory[126] = 32'h768dcfbf;
    twiddle_memory[127] = 32'h7667cf62;
    twiddle_memory[128] = 32'h7641cf05;
    twiddle_memory[129] = 32'h761acea8;
    twiddle_memory[130] = 32'h75f3ce4b;
    twiddle_memory[131] = 32'h75cccdef;
    twiddle_memory[132] = 32'h75a5cd92;
    twiddle_memory[133] = 32'h757dcd36;
    twiddle_memory[134] = 32'h7555ccda;
    twiddle_memory[135] = 32'h752dcc7d;
    twiddle_memory[136] = 32'h7504cc21;
    twiddle_memory[137] = 32'h74dbcbc6;
    twiddle_memory[138] = 32'h74b2cb6a;
    twiddle_memory[139] = 32'h7488cb0e;
    twiddle_memory[140] = 32'h745fcab3;
    twiddle_memory[141] = 32'h7435ca58;
    twiddle_memory[142] = 32'h740ac9fc;
    twiddle_memory[143] = 32'h73e0c9a1;
    twiddle_memory[144] = 32'h73b5c946;
    twiddle_memory[145] = 32'h738ac8eb;
    twiddle_memory[146] = 32'h735ec891;
    twiddle_memory[147] = 32'h7333c836;
    twiddle_memory[148] = 32'h7307c7dc;
    twiddle_memory[149] = 32'h72dbc782;
    twiddle_memory[150] = 32'h72aec727;
    twiddle_memory[151] = 32'h7281c6cd;
    twiddle_memory[152] = 32'h7254c674;
    twiddle_memory[153] = 32'h7227c61a;
    twiddle_memory[154] = 32'h71f9c5c0;
    twiddle_memory[155] = 32'h71cbc567;
    twiddle_memory[156] = 32'h719dc50e;
    twiddle_memory[157] = 32'h716fc4b4;
    twiddle_memory[158] = 32'h7140c45b;
    twiddle_memory[159] = 32'h7111c402;
    twiddle_memory[160] = 32'h70e2c3aa;
    twiddle_memory[161] = 32'h70b2c351;
    twiddle_memory[162] = 32'h7083c2f9;
    twiddle_memory[163] = 32'h7053c2a0;
    twiddle_memory[164] = 32'h7022c248;
    twiddle_memory[165] = 32'h6ff2c1f0;
    twiddle_memory[166] = 32'h6fc1c198;
    twiddle_memory[167] = 32'h6f90c141;
    twiddle_memory[168] = 32'h6f5ec0e9;
    twiddle_memory[169] = 32'h6f2cc092;
    twiddle_memory[170] = 32'h6efbc03b;
    twiddle_memory[171] = 32'h6ec8bfe3;
    twiddle_memory[172] = 32'h6e96bf8d;
    twiddle_memory[173] = 32'h6e63bf36;
    twiddle_memory[174] = 32'h6e30bedf;
    twiddle_memory[175] = 32'h6dfdbe89;
    twiddle_memory[176] = 32'h6dc9be32;
    twiddle_memory[177] = 32'h6d95bddc;
    twiddle_memory[178] = 32'h6d61bd86;
    twiddle_memory[179] = 32'h6d2dbd30;
    twiddle_memory[180] = 32'h6cf8bcdb;
    twiddle_memory[181] = 32'h6cc3bc85;
    twiddle_memory[182] = 32'h6c8ebc30;
    twiddle_memory[183] = 32'h6c59bbdb;
    twiddle_memory[184] = 32'h6c23bb86;
    twiddle_memory[185] = 32'h6bedbb31;
    twiddle_memory[186] = 32'h6bb7badc;
    twiddle_memory[187] = 32'h6b81ba88;
    twiddle_memory[188] = 32'h6b4aba33;
    twiddle_memory[189] = 32'h6b13b9df;
    twiddle_memory[190] = 32'h6adcb98b;
    twiddle_memory[191] = 32'h6aa4b937;
    twiddle_memory[192] = 32'h6a6db8e4;
    twiddle_memory[193] = 32'h6a35b890;
    twiddle_memory[194] = 32'h69fdb83d;
    twiddle_memory[195] = 32'h69c4b7ea;
    twiddle_memory[196] = 32'h698bb797;
    twiddle_memory[197] = 32'h6952b744;
    twiddle_memory[198] = 32'h6919b6f1;
    twiddle_memory[199] = 32'h68e0b69f;
    twiddle_memory[200] = 32'h68a6b64c;
    twiddle_memory[201] = 32'h686cb5fa;
    twiddle_memory[202] = 32'h6832b5a8;
    twiddle_memory[203] = 32'h67f7b557;
    twiddle_memory[204] = 32'h67bcb505;
    twiddle_memory[205] = 32'h6781b4b4;
    twiddle_memory[206] = 32'h6746b463;
    twiddle_memory[207] = 32'h670ab412;
    twiddle_memory[208] = 32'h66cfb3c1;
    twiddle_memory[209] = 32'h6693b370;
    twiddle_memory[210] = 32'h6656b320;
    twiddle_memory[211] = 32'h661ab2cf;
    twiddle_memory[212] = 32'h65ddb27f;
    twiddle_memory[213] = 32'h65a0b22f;
    twiddle_memory[214] = 32'h6563b1e0;
    twiddle_memory[215] = 32'h6525b190;
    twiddle_memory[216] = 32'h64e8b141;
    twiddle_memory[217] = 32'h64aab0f2;
    twiddle_memory[218] = 32'h646cb0a3;
    twiddle_memory[219] = 32'h642db054;
    twiddle_memory[220] = 32'h63eeb005;
    twiddle_memory[221] = 32'h63afafb7;
    twiddle_memory[222] = 32'h6370af69;
    twiddle_memory[223] = 32'h6331af1b;
    twiddle_memory[224] = 32'h62f1aecd;
    twiddle_memory[225] = 32'h62b1ae7f;
    twiddle_memory[226] = 32'h6271ae32;
    twiddle_memory[227] = 32'h6231ade5;
    twiddle_memory[228] = 32'h61f0ad98;
    twiddle_memory[229] = 32'h61afad4b;
    twiddle_memory[230] = 32'h616eacfe;
    twiddle_memory[231] = 32'h612dacb2;
    twiddle_memory[232] = 32'h60ebac65;
    twiddle_memory[233] = 32'h60aaac19;
    twiddle_memory[234] = 32'h6068abce;
    twiddle_memory[235] = 32'h6025ab82;
    twiddle_memory[236] = 32'h5fe3ab37;
    twiddle_memory[237] = 32'h5fa0aaeb;
    twiddle_memory[238] = 32'h5f5daaa0;
    twiddle_memory[239] = 32'h5f1aaa56;
    twiddle_memory[240] = 32'h5ed7aa0b;
    twiddle_memory[241] = 32'h5e93a9c1;
    twiddle_memory[242] = 32'h5e4fa976;
    twiddle_memory[243] = 32'h5e0ba92d;
    twiddle_memory[244] = 32'h5dc7a8e3;
    twiddle_memory[245] = 32'h5d82a899;
    twiddle_memory[246] = 32'h5d3ea850;
    twiddle_memory[247] = 32'h5cf9a807;
    twiddle_memory[248] = 32'h5cb3a7be;
    twiddle_memory[249] = 32'h5c6ea775;
    twiddle_memory[250] = 32'h5c28a72d;
    twiddle_memory[251] = 32'h5be2a6e4;
    twiddle_memory[252] = 32'h5b9ca69c;
    twiddle_memory[253] = 32'h5b56a654;
    twiddle_memory[254] = 32'h5b0fa60d;
    twiddle_memory[255] = 32'h5ac9a5c5;
    twiddle_memory[256] = 32'h5a82a57e;
    twiddle_memory[257] = 32'h5a3ba537;
    twiddle_memory[258] = 32'h59f3a4f1;
    twiddle_memory[259] = 32'h59aca4aa;
    twiddle_memory[260] = 32'h5964a464;
    twiddle_memory[261] = 32'h591ca41e;
    twiddle_memory[262] = 32'h58d3a3d8;
    twiddle_memory[263] = 32'h588ba392;
    twiddle_memory[264] = 32'h5842a34d;
    twiddle_memory[265] = 32'h57f9a307;
    twiddle_memory[266] = 32'h57b0a2c2;
    twiddle_memory[267] = 32'h5767a27e;
    twiddle_memory[268] = 32'h571da239;
    twiddle_memory[269] = 32'h56d3a1f5;
    twiddle_memory[270] = 32'h568aa1b1;
    twiddle_memory[271] = 32'h563fa16d;
    twiddle_memory[272] = 32'h55f5a129;
    twiddle_memory[273] = 32'h55aaa0e6;
    twiddle_memory[274] = 32'h5560a0a3;
    twiddle_memory[275] = 32'h5515a060;
    twiddle_memory[276] = 32'h54c9a01d;
    twiddle_memory[277] = 32'h547e9fdb;
    twiddle_memory[278] = 32'h54329f98;
    twiddle_memory[279] = 32'h53e79f56;
    twiddle_memory[280] = 32'h539b9f15;
    twiddle_memory[281] = 32'h534e9ed3;
    twiddle_memory[282] = 32'h53029e92;
    twiddle_memory[283] = 32'h52b59e51;
    twiddle_memory[284] = 32'h52689e10;
    twiddle_memory[285] = 32'h521b9dcf;
    twiddle_memory[286] = 32'h51ce9d8f;
    twiddle_memory[287] = 32'h51819d4f;
    twiddle_memory[288] = 32'h51339d0f;
    twiddle_memory[289] = 32'h50e59ccf;
    twiddle_memory[290] = 32'h50979c90;
    twiddle_memory[291] = 32'h50499c51;
    twiddle_memory[292] = 32'h4ffb9c12;
    twiddle_memory[293] = 32'h4fac9bd3;
    twiddle_memory[294] = 32'h4f5d9b94;
    twiddle_memory[295] = 32'h4f0e9b56;
    twiddle_memory[296] = 32'h4ebf9b18;
    twiddle_memory[297] = 32'h4e709adb;
    twiddle_memory[298] = 32'h4e209a9d;
    twiddle_memory[299] = 32'h4dd19a60;
    twiddle_memory[300] = 32'h4d819a23;
    twiddle_memory[301] = 32'h4d3199e6;
    twiddle_memory[302] = 32'h4ce099aa;
    twiddle_memory[303] = 32'h4c90996d;
    twiddle_memory[304] = 32'h4c3f9931;
    twiddle_memory[305] = 32'h4bee98f6;
    twiddle_memory[306] = 32'h4b9d98ba;
    twiddle_memory[307] = 32'h4b4c987f;
    twiddle_memory[308] = 32'h4afb9844;
    twiddle_memory[309] = 32'h4aa99809;
    twiddle_memory[310] = 32'h4a5897ce;
    twiddle_memory[311] = 32'h4a069794;
    twiddle_memory[312] = 32'h49b4975a;
    twiddle_memory[313] = 32'h49619720;
    twiddle_memory[314] = 32'h490f96e7;
    twiddle_memory[315] = 32'h48bc96ae;
    twiddle_memory[316] = 32'h48699675;
    twiddle_memory[317] = 32'h4816963c;
    twiddle_memory[318] = 32'h47c39603;
    twiddle_memory[319] = 32'h477095cb;
    twiddle_memory[320] = 32'h471c9593;
    twiddle_memory[321] = 32'h46c9955c;
    twiddle_memory[322] = 32'h46759524;
    twiddle_memory[323] = 32'h462194ed;
    twiddle_memory[324] = 32'h45cd94b6;
    twiddle_memory[325] = 32'h4578947f;
    twiddle_memory[326] = 32'h45249449;
    twiddle_memory[327] = 32'h44cf9413;
    twiddle_memory[328] = 32'h447a93dd;
    twiddle_memory[329] = 32'h442593a7;
    twiddle_memory[330] = 32'h43d09372;
    twiddle_memory[331] = 32'h437b933d;
    twiddle_memory[332] = 32'h43259308;
    twiddle_memory[333] = 32'h42d092d3;
    twiddle_memory[334] = 32'h427a929f;
    twiddle_memory[335] = 32'h4224926b;
    twiddle_memory[336] = 32'h41ce9237;
    twiddle_memory[337] = 32'h41779203;
    twiddle_memory[338] = 32'h412191d0;
    twiddle_memory[339] = 32'h40ca919d;
    twiddle_memory[340] = 32'h4073916a;
    twiddle_memory[341] = 32'h401d9138;
    twiddle_memory[342] = 32'h3fc59105;
    twiddle_memory[343] = 32'h3f6e90d4;
    twiddle_memory[344] = 32'h3f1790a2;
    twiddle_memory[345] = 32'h3ebf9070;
    twiddle_memory[346] = 32'h3e68903f;
    twiddle_memory[347] = 32'h3e10900e;
    twiddle_memory[348] = 32'h3db88fde;
    twiddle_memory[349] = 32'h3d608fad;
    twiddle_memory[350] = 32'h3d078f7d;
    twiddle_memory[351] = 32'h3caf8f4e;
    twiddle_memory[352] = 32'h3c568f1e;
    twiddle_memory[353] = 32'h3bfe8eef;
    twiddle_memory[354] = 32'h3ba58ec0;
    twiddle_memory[355] = 32'h3b4c8e91;
    twiddle_memory[356] = 32'h3af28e63;
    twiddle_memory[357] = 32'h3a998e35;
    twiddle_memory[358] = 32'h3a408e07;
    twiddle_memory[359] = 32'h39e68dd9;
    twiddle_memory[360] = 32'h398c8dac;
    twiddle_memory[361] = 32'h39338d7f;
    twiddle_memory[362] = 32'h38d98d52;
    twiddle_memory[363] = 32'h387e8d25;
    twiddle_memory[364] = 32'h38248cf9;
    twiddle_memory[365] = 32'h37ca8ccd;
    twiddle_memory[366] = 32'h376f8ca2;
    twiddle_memory[367] = 32'h37158c76;
    twiddle_memory[368] = 32'h36ba8c4b;
    twiddle_memory[369] = 32'h365f8c20;
    twiddle_memory[370] = 32'h36048bf6;
    twiddle_memory[371] = 32'h35a88bcb;
    twiddle_memory[372] = 32'h354d8ba1;
    twiddle_memory[373] = 32'h34f28b78;
    twiddle_memory[374] = 32'h34968b4e;
    twiddle_memory[375] = 32'h343a8b25;
    twiddle_memory[376] = 32'h33df8afc;
    twiddle_memory[377] = 32'h33838ad3;
    twiddle_memory[378] = 32'h33268aab;
    twiddle_memory[379] = 32'h32ca8a83;
    twiddle_memory[380] = 32'h326e8a5b;
    twiddle_memory[381] = 32'h32118a34;
    twiddle_memory[382] = 32'h31b58a0d;
    twiddle_memory[383] = 32'h315889e6;
    twiddle_memory[384] = 32'h30fb89bf;
    twiddle_memory[385] = 32'h309e8999;
    twiddle_memory[386] = 32'h30418973;
    twiddle_memory[387] = 32'h2fe4894d;
    twiddle_memory[388] = 32'h2f878928;
    twiddle_memory[389] = 32'h2f2a8902;
    twiddle_memory[390] = 32'h2ecc88de;
    twiddle_memory[391] = 32'h2e6e88b9;
    twiddle_memory[392] = 32'h2e118895;
    twiddle_memory[393] = 32'h2db38871;
    twiddle_memory[394] = 32'h2d55884d;
    twiddle_memory[395] = 32'h2cf78829;
    twiddle_memory[396] = 32'h2c998806;
    twiddle_memory[397] = 32'h2c3a87e3;
    twiddle_memory[398] = 32'h2bdc87c1;
    twiddle_memory[399] = 32'h2b7d879e;
    twiddle_memory[400] = 32'h2b1f877c;
    twiddle_memory[401] = 32'h2ac0875b;
    twiddle_memory[402] = 32'h2a618739;
    twiddle_memory[403] = 32'h2a028718;
    twiddle_memory[404] = 32'h29a386f7;
    twiddle_memory[405] = 32'h294486d7;
    twiddle_memory[406] = 32'h28e586b6;
    twiddle_memory[407] = 32'h28868696;
    twiddle_memory[408] = 32'h28268677;
    twiddle_memory[409] = 32'h27c78657;
    twiddle_memory[410] = 32'h27678638;
    twiddle_memory[411] = 32'h2708861a;
    twiddle_memory[412] = 32'h26a885fb;
    twiddle_memory[413] = 32'h264885dd;
    twiddle_memory[414] = 32'h25e885bf;
    twiddle_memory[415] = 32'h258885a1;
    twiddle_memory[416] = 32'h25288584;
    twiddle_memory[417] = 32'h24c88567;
    twiddle_memory[418] = 32'h2467854a;
    twiddle_memory[419] = 32'h2407852e;
    twiddle_memory[420] = 32'h23a68512;
    twiddle_memory[421] = 32'h234684f6;
    twiddle_memory[422] = 32'h22e584da;
    twiddle_memory[423] = 32'h228484bf;
    twiddle_memory[424] = 32'h222384a4;
    twiddle_memory[425] = 32'h21c28489;
    twiddle_memory[426] = 32'h2161846f;
    twiddle_memory[427] = 32'h21008455;
    twiddle_memory[428] = 32'h209f843b;
    twiddle_memory[429] = 32'h203e8422;
    twiddle_memory[430] = 32'h1fdd8408;
    twiddle_memory[431] = 32'h1f7b83f0;
    twiddle_memory[432] = 32'h1f1a83d7;
    twiddle_memory[433] = 32'h1eb883bf;
    twiddle_memory[434] = 32'h1e5783a7;
    twiddle_memory[435] = 32'h1df5838f;
    twiddle_memory[436] = 32'h1d938378;
    twiddle_memory[437] = 32'h1d318361;
    twiddle_memory[438] = 32'h1ccf834a;
    twiddle_memory[439] = 32'h1c6d8333;
    twiddle_memory[440] = 32'h1c0b831d;
    twiddle_memory[441] = 32'h1ba98307;
    twiddle_memory[442] = 32'h1b4782f2;
    twiddle_memory[443] = 32'h1ae582dc;
    twiddle_memory[444] = 32'h1a8282c7;
    twiddle_memory[445] = 32'h1a2082b3;
    twiddle_memory[446] = 32'h19be829e;
    twiddle_memory[447] = 32'h195b828a;
    twiddle_memory[448] = 32'h18f98277;
    twiddle_memory[449] = 32'h18968263;
    twiddle_memory[450] = 32'h18338250;
    twiddle_memory[451] = 32'h17d0823d;
    twiddle_memory[452] = 32'h176e822b;
    twiddle_memory[453] = 32'h170b8218;
    twiddle_memory[454] = 32'h16a88206;
    twiddle_memory[455] = 32'h164581f5;
    twiddle_memory[456] = 32'h15e281e3;
    twiddle_memory[457] = 32'h157f81d2;
    twiddle_memory[458] = 32'h151c81c2;
    twiddle_memory[459] = 32'h14b981b1;
    twiddle_memory[460] = 32'h145581a1;
    twiddle_memory[461] = 32'h13f28191;
    twiddle_memory[462] = 32'h138f8182;
    twiddle_memory[463] = 32'h132b8173;
    twiddle_memory[464] = 32'h12c88164;
    twiddle_memory[465] = 32'h12648155;
    twiddle_memory[466] = 32'h12018147;
    twiddle_memory[467] = 32'h119d8139;
    twiddle_memory[468] = 32'h113a812b;
    twiddle_memory[469] = 32'h10d6811e;
    twiddle_memory[470] = 32'h10728111;
    twiddle_memory[471] = 32'h100f8104;
    twiddle_memory[472] = 32'h0fab80f7;
    twiddle_memory[473] = 32'h0f4780eb;
    twiddle_memory[474] = 32'h0ee380df;
    twiddle_memory[475] = 32'h0e8080d4;
    twiddle_memory[476] = 32'h0e1c80c9;
    twiddle_memory[477] = 32'h0db880be;
    twiddle_memory[478] = 32'h0d5480b3;
    twiddle_memory[479] = 32'h0cf080a9;
    twiddle_memory[480] = 32'h0c8c809f;
    twiddle_memory[481] = 32'h0c288095;
    twiddle_memory[482] = 32'h0bc4808c;
    twiddle_memory[483] = 32'h0b5f8083;
    twiddle_memory[484] = 32'h0afb807a;
    twiddle_memory[485] = 32'h0a978071;
    twiddle_memory[486] = 32'h0a338069;
    twiddle_memory[487] = 32'h09cf8061;
    twiddle_memory[488] = 32'h096a805a;
    twiddle_memory[489] = 32'h09068053;
    twiddle_memory[490] = 32'h08a2804c;
    twiddle_memory[491] = 32'h083e8045;
    twiddle_memory[492] = 32'h07d9803f;
    twiddle_memory[493] = 32'h07758039;
    twiddle_memory[494] = 32'h07118033;
    twiddle_memory[495] = 32'h06ac802e;
    twiddle_memory[496] = 32'h06488028;
    twiddle_memory[497] = 32'h05e38024;
    twiddle_memory[498] = 32'h057f801f;
    twiddle_memory[499] = 32'h051b801b;
    twiddle_memory[500] = 32'h04b68017;
    twiddle_memory[501] = 32'h04528014;
    twiddle_memory[502] = 32'h03ed8010;
    twiddle_memory[503] = 32'h0389800d;
    twiddle_memory[504] = 32'h0324800b;
    twiddle_memory[505] = 32'h02c08009;
    twiddle_memory[506] = 32'h025b8007;
    twiddle_memory[507] = 32'h01f78005;
    twiddle_memory[508] = 32'h01928003;
    twiddle_memory[509] = 32'h012e8002;
    twiddle_memory[510] = 32'h00c98002;
    twiddle_memory[511] = 32'h00658001;
    twiddle_memory[512] = 32'h00008001;
    twiddle_memory[513] = 32'hff9b8001;
    twiddle_memory[514] = 32'hff378002;
    twiddle_memory[515] = 32'hfed28002;
    twiddle_memory[516] = 32'hfe6e8003;
    twiddle_memory[517] = 32'hfe098005;
    twiddle_memory[518] = 32'hfda58007;
    twiddle_memory[519] = 32'hfd408009;
    twiddle_memory[520] = 32'hfcdc800b;
    twiddle_memory[521] = 32'hfc77800d;
    twiddle_memory[522] = 32'hfc138010;
    twiddle_memory[523] = 32'hfbae8014;
    twiddle_memory[524] = 32'hfb4a8017;
    twiddle_memory[525] = 32'hfae5801b;
    twiddle_memory[526] = 32'hfa81801f;
    twiddle_memory[527] = 32'hfa1d8024;
    twiddle_memory[528] = 32'hf9b88028;
    twiddle_memory[529] = 32'hf954802e;
    twiddle_memory[530] = 32'hf8ef8033;
    twiddle_memory[531] = 32'hf88b8039;
    twiddle_memory[532] = 32'hf827803f;
    twiddle_memory[533] = 32'hf7c28045;
    twiddle_memory[534] = 32'hf75e804c;
    twiddle_memory[535] = 32'hf6fa8053;
    twiddle_memory[536] = 32'hf696805a;
    twiddle_memory[537] = 32'hf6318061;
    twiddle_memory[538] = 32'hf5cd8069;
    twiddle_memory[539] = 32'hf5698071;
    twiddle_memory[540] = 32'hf505807a;
    twiddle_memory[541] = 32'hf4a18083;
    twiddle_memory[542] = 32'hf43c808c;
    twiddle_memory[543] = 32'hf3d88095;
    twiddle_memory[544] = 32'hf374809f;
    twiddle_memory[545] = 32'hf31080a9;
    twiddle_memory[546] = 32'hf2ac80b3;
    twiddle_memory[547] = 32'hf24880be;
    twiddle_memory[548] = 32'hf1e480c9;
    twiddle_memory[549] = 32'hf18080d4;
    twiddle_memory[550] = 32'hf11d80df;
    twiddle_memory[551] = 32'hf0b980eb;
    twiddle_memory[552] = 32'hf05580f7;
    twiddle_memory[553] = 32'heff18104;
    twiddle_memory[554] = 32'hef8e8111;
    twiddle_memory[555] = 32'hef2a811e;
    twiddle_memory[556] = 32'heec6812b;
    twiddle_memory[557] = 32'hee638139;
    twiddle_memory[558] = 32'hedff8147;
    twiddle_memory[559] = 32'hed9c8155;
    twiddle_memory[560] = 32'hed388164;
    twiddle_memory[561] = 32'hecd58173;
    twiddle_memory[562] = 32'hec718182;
    twiddle_memory[563] = 32'hec0e8191;
    twiddle_memory[564] = 32'hebab81a1;
    twiddle_memory[565] = 32'heb4781b1;
    twiddle_memory[566] = 32'heae481c2;
    twiddle_memory[567] = 32'hea8181d2;
    twiddle_memory[568] = 32'hea1e81e3;
    twiddle_memory[569] = 32'he9bb81f5;
    twiddle_memory[570] = 32'he9588206;
    twiddle_memory[571] = 32'he8f58218;
    twiddle_memory[572] = 32'he892822b;
    twiddle_memory[573] = 32'he830823d;
    twiddle_memory[574] = 32'he7cd8250;
    twiddle_memory[575] = 32'he76a8263;
    twiddle_memory[576] = 32'he7078277;
    twiddle_memory[577] = 32'he6a5828a;
    twiddle_memory[578] = 32'he642829e;
    twiddle_memory[579] = 32'he5e082b3;
    twiddle_memory[580] = 32'he57e82c7;
    twiddle_memory[581] = 32'he51b82dc;
    twiddle_memory[582] = 32'he4b982f2;
    twiddle_memory[583] = 32'he4578307;
    twiddle_memory[584] = 32'he3f5831d;
    twiddle_memory[585] = 32'he3938333;
    twiddle_memory[586] = 32'he331834a;
    twiddle_memory[587] = 32'he2cf8361;
    twiddle_memory[588] = 32'he26d8378;
    twiddle_memory[589] = 32'he20b838f;
    twiddle_memory[590] = 32'he1a983a7;
    twiddle_memory[591] = 32'he14883bf;
    twiddle_memory[592] = 32'he0e683d7;
    twiddle_memory[593] = 32'he08583f0;
    twiddle_memory[594] = 32'he0238408;
    twiddle_memory[595] = 32'hdfc28422;
    twiddle_memory[596] = 32'hdf61843b;
    twiddle_memory[597] = 32'hdf008455;
    twiddle_memory[598] = 32'hde9f846f;
    twiddle_memory[599] = 32'hde3e8489;
    twiddle_memory[600] = 32'hdddd84a4;
    twiddle_memory[601] = 32'hdd7c84bf;
    twiddle_memory[602] = 32'hdd1b84da;
    twiddle_memory[603] = 32'hdcba84f6;
    twiddle_memory[604] = 32'hdc5a8512;
    twiddle_memory[605] = 32'hdbf9852e;
    twiddle_memory[606] = 32'hdb99854a;
    twiddle_memory[607] = 32'hdb388567;
    twiddle_memory[608] = 32'hdad88584;
    twiddle_memory[609] = 32'hda7885a1;
    twiddle_memory[610] = 32'hda1885bf;
    twiddle_memory[611] = 32'hd9b885dd;
    twiddle_memory[612] = 32'hd95885fb;
    twiddle_memory[613] = 32'hd8f8861a;
    twiddle_memory[614] = 32'hd8998638;
    twiddle_memory[615] = 32'hd8398657;
    twiddle_memory[616] = 32'hd7da8677;
    twiddle_memory[617] = 32'hd77a8696;
    twiddle_memory[618] = 32'hd71b86b6;
    twiddle_memory[619] = 32'hd6bc86d7;
    twiddle_memory[620] = 32'hd65d86f7;
    twiddle_memory[621] = 32'hd5fe8718;
    twiddle_memory[622] = 32'hd59f8739;
    twiddle_memory[623] = 32'hd540875b;
    twiddle_memory[624] = 32'hd4e1877c;
    twiddle_memory[625] = 32'hd483879e;
    twiddle_memory[626] = 32'hd42487c1;
    twiddle_memory[627] = 32'hd3c687e3;
    twiddle_memory[628] = 32'hd3678806;
    twiddle_memory[629] = 32'hd3098829;
    twiddle_memory[630] = 32'hd2ab884d;
    twiddle_memory[631] = 32'hd24d8871;
    twiddle_memory[632] = 32'hd1ef8895;
    twiddle_memory[633] = 32'hd19288b9;
    twiddle_memory[634] = 32'hd13488de;
    twiddle_memory[635] = 32'hd0d68902;
    twiddle_memory[636] = 32'hd0798928;
    twiddle_memory[637] = 32'hd01c894d;
    twiddle_memory[638] = 32'hcfbf8973;
    twiddle_memory[639] = 32'hcf628999;
    twiddle_memory[640] = 32'hcf0589bf;
    twiddle_memory[641] = 32'hcea889e6;
    twiddle_memory[642] = 32'hce4b8a0d;
    twiddle_memory[643] = 32'hcdef8a34;
    twiddle_memory[644] = 32'hcd928a5b;
    twiddle_memory[645] = 32'hcd368a83;
    twiddle_memory[646] = 32'hccda8aab;
    twiddle_memory[647] = 32'hcc7d8ad3;
    twiddle_memory[648] = 32'hcc218afc;
    twiddle_memory[649] = 32'hcbc68b25;
    twiddle_memory[650] = 32'hcb6a8b4e;
    twiddle_memory[651] = 32'hcb0e8b78;
    twiddle_memory[652] = 32'hcab38ba1;
    twiddle_memory[653] = 32'hca588bcb;
    twiddle_memory[654] = 32'hc9fc8bf6;
    twiddle_memory[655] = 32'hc9a18c20;
    twiddle_memory[656] = 32'hc9468c4b;
    twiddle_memory[657] = 32'hc8eb8c76;
    twiddle_memory[658] = 32'hc8918ca2;
    twiddle_memory[659] = 32'hc8368ccd;
    twiddle_memory[660] = 32'hc7dc8cf9;
    twiddle_memory[661] = 32'hc7828d25;
    twiddle_memory[662] = 32'hc7278d52;
    twiddle_memory[663] = 32'hc6cd8d7f;
    twiddle_memory[664] = 32'hc6748dac;
    twiddle_memory[665] = 32'hc61a8dd9;
    twiddle_memory[666] = 32'hc5c08e07;
    twiddle_memory[667] = 32'hc5678e35;
    twiddle_memory[668] = 32'hc50e8e63;
    twiddle_memory[669] = 32'hc4b48e91;
    twiddle_memory[670] = 32'hc45b8ec0;
    twiddle_memory[671] = 32'hc4028eef;
    twiddle_memory[672] = 32'hc3aa8f1e;
    twiddle_memory[673] = 32'hc3518f4e;
    twiddle_memory[674] = 32'hc2f98f7d;
    twiddle_memory[675] = 32'hc2a08fad;
    twiddle_memory[676] = 32'hc2488fde;
    twiddle_memory[677] = 32'hc1f0900e;
    twiddle_memory[678] = 32'hc198903f;
    twiddle_memory[679] = 32'hc1419070;
    twiddle_memory[680] = 32'hc0e990a2;
    twiddle_memory[681] = 32'hc09290d4;
    twiddle_memory[682] = 32'hc03b9105;
    twiddle_memory[683] = 32'hbfe39138;
    twiddle_memory[684] = 32'hbf8d916a;
    twiddle_memory[685] = 32'hbf36919d;
    twiddle_memory[686] = 32'hbedf91d0;
    twiddle_memory[687] = 32'hbe899203;
    twiddle_memory[688] = 32'hbe329237;
    twiddle_memory[689] = 32'hbddc926b;
    twiddle_memory[690] = 32'hbd86929f;
    twiddle_memory[691] = 32'hbd3092d3;
    twiddle_memory[692] = 32'hbcdb9308;
    twiddle_memory[693] = 32'hbc85933d;
    twiddle_memory[694] = 32'hbc309372;
    twiddle_memory[695] = 32'hbbdb93a7;
    twiddle_memory[696] = 32'hbb8693dd;
    twiddle_memory[697] = 32'hbb319413;
    twiddle_memory[698] = 32'hbadc9449;
    twiddle_memory[699] = 32'hba88947f;
    twiddle_memory[700] = 32'hba3394b6;
    twiddle_memory[701] = 32'hb9df94ed;
    twiddle_memory[702] = 32'hb98b9524;
    twiddle_memory[703] = 32'hb937955c;
    twiddle_memory[704] = 32'hb8e49593;
    twiddle_memory[705] = 32'hb89095cb;
    twiddle_memory[706] = 32'hb83d9603;
    twiddle_memory[707] = 32'hb7ea963c;
    twiddle_memory[708] = 32'hb7979675;
    twiddle_memory[709] = 32'hb74496ae;
    twiddle_memory[710] = 32'hb6f196e7;
    twiddle_memory[711] = 32'hb69f9720;
    twiddle_memory[712] = 32'hb64c975a;
    twiddle_memory[713] = 32'hb5fa9794;
    twiddle_memory[714] = 32'hb5a897ce;
    twiddle_memory[715] = 32'hb5579809;
    twiddle_memory[716] = 32'hb5059844;
    twiddle_memory[717] = 32'hb4b4987f;
    twiddle_memory[718] = 32'hb46398ba;
    twiddle_memory[719] = 32'hb41298f6;
    twiddle_memory[720] = 32'hb3c19931;
    twiddle_memory[721] = 32'hb370996d;
    twiddle_memory[722] = 32'hb32099aa;
    twiddle_memory[723] = 32'hb2cf99e6;
    twiddle_memory[724] = 32'hb27f9a23;
    twiddle_memory[725] = 32'hb22f9a60;
    twiddle_memory[726] = 32'hb1e09a9d;
    twiddle_memory[727] = 32'hb1909adb;
    twiddle_memory[728] = 32'hb1419b18;
    twiddle_memory[729] = 32'hb0f29b56;
    twiddle_memory[730] = 32'hb0a39b94;
    twiddle_memory[731] = 32'hb0549bd3;
    twiddle_memory[732] = 32'hb0059c12;
    twiddle_memory[733] = 32'hafb79c51;
    twiddle_memory[734] = 32'haf699c90;
    twiddle_memory[735] = 32'haf1b9ccf;
    twiddle_memory[736] = 32'haecd9d0f;
    twiddle_memory[737] = 32'hae7f9d4f;
    twiddle_memory[738] = 32'hae329d8f;
    twiddle_memory[739] = 32'hade59dcf;
    twiddle_memory[740] = 32'had989e10;
    twiddle_memory[741] = 32'had4b9e51;
    twiddle_memory[742] = 32'hacfe9e92;
    twiddle_memory[743] = 32'hacb29ed3;
    twiddle_memory[744] = 32'hac659f15;
    twiddle_memory[745] = 32'hac199f56;
    twiddle_memory[746] = 32'habce9f98;
    twiddle_memory[747] = 32'hab829fdb;
    twiddle_memory[748] = 32'hab37a01d;
    twiddle_memory[749] = 32'haaeba060;
    twiddle_memory[750] = 32'haaa0a0a3;
    twiddle_memory[751] = 32'haa56a0e6;
    twiddle_memory[752] = 32'haa0ba129;
    twiddle_memory[753] = 32'ha9c1a16d;
    twiddle_memory[754] = 32'ha976a1b1;
    twiddle_memory[755] = 32'ha92da1f5;
    twiddle_memory[756] = 32'ha8e3a239;
    twiddle_memory[757] = 32'ha899a27e;
    twiddle_memory[758] = 32'ha850a2c2;
    twiddle_memory[759] = 32'ha807a307;
    twiddle_memory[760] = 32'ha7bea34d;
    twiddle_memory[761] = 32'ha775a392;
    twiddle_memory[762] = 32'ha72da3d8;
    twiddle_memory[763] = 32'ha6e4a41e;
    twiddle_memory[764] = 32'ha69ca464;
    twiddle_memory[765] = 32'ha654a4aa;
    twiddle_memory[766] = 32'ha60da4f1;
    twiddle_memory[767] = 32'ha5c5a537;
    twiddle_memory[768] = 32'ha57ea57e;
    twiddle_memory[769] = 32'ha537a5c5;
    twiddle_memory[770] = 32'ha4f1a60d;
    twiddle_memory[771] = 32'ha4aaa654;
    twiddle_memory[772] = 32'ha464a69c;
    twiddle_memory[773] = 32'ha41ea6e4;
    twiddle_memory[774] = 32'ha3d8a72d;
    twiddle_memory[775] = 32'ha392a775;
    twiddle_memory[776] = 32'ha34da7be;
    twiddle_memory[777] = 32'ha307a807;
    twiddle_memory[778] = 32'ha2c2a850;
    twiddle_memory[779] = 32'ha27ea899;
    twiddle_memory[780] = 32'ha239a8e3;
    twiddle_memory[781] = 32'ha1f5a92d;
    twiddle_memory[782] = 32'ha1b1a976;
    twiddle_memory[783] = 32'ha16da9c1;
    twiddle_memory[784] = 32'ha129aa0b;
    twiddle_memory[785] = 32'ha0e6aa56;
    twiddle_memory[786] = 32'ha0a3aaa0;
    twiddle_memory[787] = 32'ha060aaeb;
    twiddle_memory[788] = 32'ha01dab37;
    twiddle_memory[789] = 32'h9fdbab82;
    twiddle_memory[790] = 32'h9f98abce;
    twiddle_memory[791] = 32'h9f56ac19;
    twiddle_memory[792] = 32'h9f15ac65;
    twiddle_memory[793] = 32'h9ed3acb2;
    twiddle_memory[794] = 32'h9e92acfe;
    twiddle_memory[795] = 32'h9e51ad4b;
    twiddle_memory[796] = 32'h9e10ad98;
    twiddle_memory[797] = 32'h9dcfade5;
    twiddle_memory[798] = 32'h9d8fae32;
    twiddle_memory[799] = 32'h9d4fae7f;
    twiddle_memory[800] = 32'h9d0faecd;
    twiddle_memory[801] = 32'h9ccfaf1b;
    twiddle_memory[802] = 32'h9c90af69;
    twiddle_memory[803] = 32'h9c51afb7;
    twiddle_memory[804] = 32'h9c12b005;
    twiddle_memory[805] = 32'h9bd3b054;
    twiddle_memory[806] = 32'h9b94b0a3;
    twiddle_memory[807] = 32'h9b56b0f2;
    twiddle_memory[808] = 32'h9b18b141;
    twiddle_memory[809] = 32'h9adbb190;
    twiddle_memory[810] = 32'h9a9db1e0;
    twiddle_memory[811] = 32'h9a60b22f;
    twiddle_memory[812] = 32'h9a23b27f;
    twiddle_memory[813] = 32'h99e6b2cf;
    twiddle_memory[814] = 32'h99aab320;
    twiddle_memory[815] = 32'h996db370;
    twiddle_memory[816] = 32'h9931b3c1;
    twiddle_memory[817] = 32'h98f6b412;
    twiddle_memory[818] = 32'h98bab463;
    twiddle_memory[819] = 32'h987fb4b4;
    twiddle_memory[820] = 32'h9844b505;
    twiddle_memory[821] = 32'h9809b557;
    twiddle_memory[822] = 32'h97ceb5a8;
    twiddle_memory[823] = 32'h9794b5fa;
    twiddle_memory[824] = 32'h975ab64c;
    twiddle_memory[825] = 32'h9720b69f;
    twiddle_memory[826] = 32'h96e7b6f1;
    twiddle_memory[827] = 32'h96aeb744;
    twiddle_memory[828] = 32'h9675b797;
    twiddle_memory[829] = 32'h963cb7ea;
    twiddle_memory[830] = 32'h9603b83d;
    twiddle_memory[831] = 32'h95cbb890;
    twiddle_memory[832] = 32'h9593b8e4;
    twiddle_memory[833] = 32'h955cb937;
    twiddle_memory[834] = 32'h9524b98b;
    twiddle_memory[835] = 32'h94edb9df;
    twiddle_memory[836] = 32'h94b6ba33;
    twiddle_memory[837] = 32'h947fba88;
    twiddle_memory[838] = 32'h9449badc;
    twiddle_memory[839] = 32'h9413bb31;
    twiddle_memory[840] = 32'h93ddbb86;
    twiddle_memory[841] = 32'h93a7bbdb;
    twiddle_memory[842] = 32'h9372bc30;
    twiddle_memory[843] = 32'h933dbc85;
    twiddle_memory[844] = 32'h9308bcdb;
    twiddle_memory[845] = 32'h92d3bd30;
    twiddle_memory[846] = 32'h929fbd86;
    twiddle_memory[847] = 32'h926bbddc;
    twiddle_memory[848] = 32'h9237be32;
    twiddle_memory[849] = 32'h9203be89;
    twiddle_memory[850] = 32'h91d0bedf;
    twiddle_memory[851] = 32'h919dbf36;
    twiddle_memory[852] = 32'h916abf8d;
    twiddle_memory[853] = 32'h9138bfe3;
    twiddle_memory[854] = 32'h9105c03b;
    twiddle_memory[855] = 32'h90d4c092;
    twiddle_memory[856] = 32'h90a2c0e9;
    twiddle_memory[857] = 32'h9070c141;
    twiddle_memory[858] = 32'h903fc198;
    twiddle_memory[859] = 32'h900ec1f0;
    twiddle_memory[860] = 32'h8fdec248;
    twiddle_memory[861] = 32'h8fadc2a0;
    twiddle_memory[862] = 32'h8f7dc2f9;
    twiddle_memory[863] = 32'h8f4ec351;
    twiddle_memory[864] = 32'h8f1ec3aa;
    twiddle_memory[865] = 32'h8eefc402;
    twiddle_memory[866] = 32'h8ec0c45b;
    twiddle_memory[867] = 32'h8e91c4b4;
    twiddle_memory[868] = 32'h8e63c50e;
    twiddle_memory[869] = 32'h8e35c567;
    twiddle_memory[870] = 32'h8e07c5c0;
    twiddle_memory[871] = 32'h8dd9c61a;
    twiddle_memory[872] = 32'h8dacc674;
    twiddle_memory[873] = 32'h8d7fc6cd;
    twiddle_memory[874] = 32'h8d52c727;
    twiddle_memory[875] = 32'h8d25c782;
    twiddle_memory[876] = 32'h8cf9c7dc;
    twiddle_memory[877] = 32'h8ccdc836;
    twiddle_memory[878] = 32'h8ca2c891;
    twiddle_memory[879] = 32'h8c76c8eb;
    twiddle_memory[880] = 32'h8c4bc946;
    twiddle_memory[881] = 32'h8c20c9a1;
    twiddle_memory[882] = 32'h8bf6c9fc;
    twiddle_memory[883] = 32'h8bcbca58;
    twiddle_memory[884] = 32'h8ba1cab3;
    twiddle_memory[885] = 32'h8b78cb0e;
    twiddle_memory[886] = 32'h8b4ecb6a;
    twiddle_memory[887] = 32'h8b25cbc6;
    twiddle_memory[888] = 32'h8afccc21;
    twiddle_memory[889] = 32'h8ad3cc7d;
    twiddle_memory[890] = 32'h8aabccda;
    twiddle_memory[891] = 32'h8a83cd36;
    twiddle_memory[892] = 32'h8a5bcd92;
    twiddle_memory[893] = 32'h8a34cdef;
    twiddle_memory[894] = 32'h8a0dce4b;
    twiddle_memory[895] = 32'h89e6cea8;
    twiddle_memory[896] = 32'h89bfcf05;
    twiddle_memory[897] = 32'h8999cf62;
    twiddle_memory[898] = 32'h8973cfbf;
    twiddle_memory[899] = 32'h894dd01c;
    twiddle_memory[900] = 32'h8928d079;
    twiddle_memory[901] = 32'h8902d0d6;
    twiddle_memory[902] = 32'h88ded134;
    twiddle_memory[903] = 32'h88b9d192;
    twiddle_memory[904] = 32'h8895d1ef;
    twiddle_memory[905] = 32'h8871d24d;
    twiddle_memory[906] = 32'h884dd2ab;
    twiddle_memory[907] = 32'h8829d309;
    twiddle_memory[908] = 32'h8806d367;
    twiddle_memory[909] = 32'h87e3d3c6;
    twiddle_memory[910] = 32'h87c1d424;
    twiddle_memory[911] = 32'h879ed483;
    twiddle_memory[912] = 32'h877cd4e1;
    twiddle_memory[913] = 32'h875bd540;
    twiddle_memory[914] = 32'h8739d59f;
    twiddle_memory[915] = 32'h8718d5fe;
    twiddle_memory[916] = 32'h86f7d65d;
    twiddle_memory[917] = 32'h86d7d6bc;
    twiddle_memory[918] = 32'h86b6d71b;
    twiddle_memory[919] = 32'h8696d77a;
    twiddle_memory[920] = 32'h8677d7da;
    twiddle_memory[921] = 32'h8657d839;
    twiddle_memory[922] = 32'h8638d899;
    twiddle_memory[923] = 32'h861ad8f8;
    twiddle_memory[924] = 32'h85fbd958;
    twiddle_memory[925] = 32'h85ddd9b8;
    twiddle_memory[926] = 32'h85bfda18;
    twiddle_memory[927] = 32'h85a1da78;
    twiddle_memory[928] = 32'h8584dad8;
    twiddle_memory[929] = 32'h8567db38;
    twiddle_memory[930] = 32'h854adb99;
    twiddle_memory[931] = 32'h852edbf9;
    twiddle_memory[932] = 32'h8512dc5a;
    twiddle_memory[933] = 32'h84f6dcba;
    twiddle_memory[934] = 32'h84dadd1b;
    twiddle_memory[935] = 32'h84bfdd7c;
    twiddle_memory[936] = 32'h84a4dddd;
    twiddle_memory[937] = 32'h8489de3e;
    twiddle_memory[938] = 32'h846fde9f;
    twiddle_memory[939] = 32'h8455df00;
    twiddle_memory[940] = 32'h843bdf61;
    twiddle_memory[941] = 32'h8422dfc2;
    twiddle_memory[942] = 32'h8408e023;
    twiddle_memory[943] = 32'h83f0e085;
    twiddle_memory[944] = 32'h83d7e0e6;
    twiddle_memory[945] = 32'h83bfe148;
    twiddle_memory[946] = 32'h83a7e1a9;
    twiddle_memory[947] = 32'h838fe20b;
    twiddle_memory[948] = 32'h8378e26d;
    twiddle_memory[949] = 32'h8361e2cf;
    twiddle_memory[950] = 32'h834ae331;
    twiddle_memory[951] = 32'h8333e393;
    twiddle_memory[952] = 32'h831de3f5;
    twiddle_memory[953] = 32'h8307e457;
    twiddle_memory[954] = 32'h82f2e4b9;
    twiddle_memory[955] = 32'h82dce51b;
    twiddle_memory[956] = 32'h82c7e57e;
    twiddle_memory[957] = 32'h82b3e5e0;
    twiddle_memory[958] = 32'h829ee642;
    twiddle_memory[959] = 32'h828ae6a5;
    twiddle_memory[960] = 32'h8277e707;
    twiddle_memory[961] = 32'h8263e76a;
    twiddle_memory[962] = 32'h8250e7cd;
    twiddle_memory[963] = 32'h823de830;
    twiddle_memory[964] = 32'h822be892;
    twiddle_memory[965] = 32'h8218e8f5;
    twiddle_memory[966] = 32'h8206e958;
    twiddle_memory[967] = 32'h81f5e9bb;
    twiddle_memory[968] = 32'h81e3ea1e;
    twiddle_memory[969] = 32'h81d2ea81;
    twiddle_memory[970] = 32'h81c2eae4;
    twiddle_memory[971] = 32'h81b1eb47;
    twiddle_memory[972] = 32'h81a1ebab;
    twiddle_memory[973] = 32'h8191ec0e;
    twiddle_memory[974] = 32'h8182ec71;
    twiddle_memory[975] = 32'h8173ecd5;
    twiddle_memory[976] = 32'h8164ed38;
    twiddle_memory[977] = 32'h8155ed9c;
    twiddle_memory[978] = 32'h8147edff;
    twiddle_memory[979] = 32'h8139ee63;
    twiddle_memory[980] = 32'h812beec6;
    twiddle_memory[981] = 32'h811eef2a;
    twiddle_memory[982] = 32'h8111ef8e;
    twiddle_memory[983] = 32'h8104eff1;
    twiddle_memory[984] = 32'h80f7f055;
    twiddle_memory[985] = 32'h80ebf0b9;
    twiddle_memory[986] = 32'h80dff11d;
    twiddle_memory[987] = 32'h80d4f180;
    twiddle_memory[988] = 32'h80c9f1e4;
    twiddle_memory[989] = 32'h80bef248;
    twiddle_memory[990] = 32'h80b3f2ac;
    twiddle_memory[991] = 32'h80a9f310;
    twiddle_memory[992] = 32'h809ff374;
    twiddle_memory[993] = 32'h8095f3d8;
    twiddle_memory[994] = 32'h808cf43c;
    twiddle_memory[995] = 32'h8083f4a1;
    twiddle_memory[996] = 32'h807af505;
    twiddle_memory[997] = 32'h8071f569;
    twiddle_memory[998] = 32'h8069f5cd;
    twiddle_memory[999] = 32'h8061f631;
    twiddle_memory[1000] = 32'h805af696;
    twiddle_memory[1001] = 32'h8053f6fa;
    twiddle_memory[1002] = 32'h804cf75e;
    twiddle_memory[1003] = 32'h8045f7c2;
    twiddle_memory[1004] = 32'h803ff827;
    twiddle_memory[1005] = 32'h8039f88b;
    twiddle_memory[1006] = 32'h8033f8ef;
    twiddle_memory[1007] = 32'h802ef954;
    twiddle_memory[1008] = 32'h8028f9b8;
    twiddle_memory[1009] = 32'h8024fa1d;
    twiddle_memory[1010] = 32'h801ffa81;
    twiddle_memory[1011] = 32'h801bfae5;
    twiddle_memory[1012] = 32'h8017fb4a;
    twiddle_memory[1013] = 32'h8014fbae;
    twiddle_memory[1014] = 32'h8010fc13;
    twiddle_memory[1015] = 32'h800dfc77;
    twiddle_memory[1016] = 32'h800bfcdc;
    twiddle_memory[1017] = 32'h8009fd40;
    twiddle_memory[1018] = 32'h8007fda5;
    twiddle_memory[1019] = 32'h8005fe09;
    twiddle_memory[1020] = 32'h8003fe6e;
    twiddle_memory[1021] = 32'h8002fed2;
    twiddle_memory[1022] = 32'h8002ff37;
    twiddle_memory[1023] = 32'h8001ff9b;
end
// 蝶形取数前已有地址，ROM 与 RAM 读取并行，无需增加处理周期。
always @(posedge clk) begin
    if (state==ST_RD_B) twiddle_word<=twiddle_memory[twiddle_index];
end
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
        a_data<=0;b_data<=0;p0<=0;p1<=0;p2<=0;p3<=0;
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
            ST_LATCH_B: begin b_data<=read_data;state<=ST_M0;end
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
                // 顺序构建 80 柱；首柱最终移至低字节，避免动态写入译码。
                bars_build<={bar_level,bars_build[639:8]};
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
