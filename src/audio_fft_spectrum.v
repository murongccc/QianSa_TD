// 兼容旧频段接口；板级参考模式直接输出 80 柱，不经过 32 段汇总。
module audio_fft_spectrum #(
    parameter integer FFT_POINTS=512,
    parameter integer REFERENCE_MODE=0,
    parameter integer BLOCK_BARS=0
)(
    input wire clk, input wire rst, input wire sample_valid,
    input wire [23:0] sample_pcm, input wire frame_start,
    output wire [255:0] bands, output wire [639:0] bars,
    output wire [7:0] breath_radius,
    input wire [6:0] bars_read_address,
    output wire [7:0] bars_read_data,
    output wire bars_read_valid, output wire bars_active
);
generate
    if (REFERENCE_MODE) begin: g_reference
        reference_fft_spectrum #(.FFT_POINTS(FFT_POINTS),.BLOCK_BARS(BLOCK_BARS)) u_reference (
            .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),
            .frame_start(frame_start),.bars(bars),.breath_radius(breath_radius),
            .bars_read_address(bars_read_address),.bars_read_data(bars_read_data),
            .bars_read_valid(bars_read_valid),.bars_active(bars_active));
        assign bands=256'd0;
    end else begin: g_legacy
        legacy_audio_fft_spectrum #(.FFT_POINTS(FFT_POINTS)) u_legacy (
            .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_pcm(sample_pcm),
            .frame_start(frame_start),.bands(bands));
        assign bars=640'd0;
        assign breath_radius=8'd90;
        assign bars_read_data=8'd0;
        assign bars_read_valid=1'b0;
        assign bars_active=1'b0;
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
    output wire [31:0] read_data
);
generate if(DEPTH==2048)begin: bank_32k
    // 两个 2048x32 数据区迁入 BRAM32K，读使能和原同步一拍语义保持。
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(32),.DATA_WIDTH_B(32),.ADDR_WIDTH_A(ADDR_W),.ADDR_WIDTH_B(ADDR_W),
        .DATA_DEPTH_A(DEPTH),.DATA_DEPTH_B(DEPTH),.MODE("PDPW"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),.IMPLEMENT("32K"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) ram(
        .dia(write_data),.dib(32'd0),.addra(write_addr),.addrb(read_addr),.cea(we),.ceb(re),
        .ocea(1'b0),.oceb(1'b1),.clka(clk),.clkb(clk),.wea(1'b1),.web(1'b0),.bea(1'b0),.beb(1'b0),
        .rsta(1'b0),.rstb(1'b0),.doa(),.dob(read_data));
end else begin: inferred_bank
reg [31:0] held_data;
assign read_data=held_data;
(* ram_style = "bram" *) reg [31:0] memory [0:DEPTH-1];
always @(posedge clk) begin
    if (we) memory[write_addr] <= write_data;
    if (re) held_data <= memory[read_addr];
end
end endgenerate
endmodule


// 48 kHz 参考显示链：512/1024/2048 点，逐 bin 欧氏幅度、直接插值、100*ln(1+0.1*M)。
// 参考动态移植自 RP2350_FFT，MIT 声明见 docs/third-party/RP2350_FFT-LICENSE。
// 保留 Hann 窗与采样率；立即上升、重力回落，原始峰值独立驱动呼吸。
module reference_fft_spectrum #(
    parameter integer FFT_POINTS=2048,
    parameter integer BLOCK_BARS=0
)(
    input wire clk, input wire rst, input wire sample_valid,
    input wire [23:0] sample_pcm, input wire frame_start,
    output wire [639:0] bars,
    output reg [7:0] breath_radius,
    input wire [6:0] bars_read_address,
    output wire [7:0] bars_read_data,
    output wire bars_read_valid, output wire bars_active
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
reg [31:0] a_data,b_data,p0,p1,p2,p3,result_a,result_b;
wire [31:0] twiddle_word;
wire [31:0] read_data,bank0_q,bank1_q;
reg [31:0] square_sum,sqrt_remainder;
reg [15:0] sqrt_root;
reg [3:0] sqrt_count;
reg [23:0] history_q;
reg [6:0] bar_index;
reg [18:0] magnitude_a,magnitude_b;
reg [26:0] interpolated_product;
reg signed [4:0] blend_high;
reg [22:0] blend_low_product;
reg [18:0] raw_peak,peak_envelope;
reg [7:0] radius_build;
reg [7:0] bar_level;
wire [639:0] bars_build;
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
wire fall_by_speed=held_m_q8>fall_step;
wire [10:0] fall_delta=fall_by_speed?{6'd0,fall_speed}:11'd1;
wire [10:0] fallen_integer=held_m_q8[18:8]-fall_delta;
// 两个扣减分支低八位均不变，共享高十一位减法；归零判断保持原顺序。
wire [18:0] falling_m_q8=(fall_by_speed || held_m_q8>19'd256)?
    {fallen_integer,held_m_q8[7:0]}:19'd0;
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
wire [ADDR_W-1:0] b_addr=a_addr+step;
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
// 插值差值分为有符号高五位和非负低十五位，两拍复用蝶形乘法器。
// ST_BAR_B 的 B 来自刚完成同步读取的 history_q，不能使用尚未锁存的新 B。
wire signed [19:0] blend_difference=$signed({1'b0,history_q[18:0]})-
    $signed({1'b0,magnitude_a});
wire signed [15:0] mul_a=(state==ST_BAR_B)?{1'b0,blend_difference[14:0]}:
    (state==ST_BLEND)?{{11{blend_high[4]}},blend_high}:
    (state==ST_SCAN_EVAL)?read_data[31:16]:
    (state==ST_SQUARE_I)?b_data[15:0]:
    ((state==ST_M0)||(state==ST_M2))?b_data[31:16]:b_data[15:0];
wire signed [15:0] mul_b=((state==ST_BAR_B)||(state==ST_BLEND))?{8'd0,fraction}:
    (state==ST_SCAN_EVAL)?read_data[31:16]:
    (state==ST_SQUARE_I)?b_data[15:0]:
    ((state==ST_M0)||(state==ST_M3))?twiddle_word[31:16]:twiddle_word[15:0];
wire signed [31:0] product=mul_a*mul_b;
// 中间值保留符号与保护位，重建完整非负加权和后才取原来的 [26:8]。
wire signed [28:0] blend_reconstructed=$signed({2'd0,magnitude_a,8'd0})+
    ($signed({{16{product[12]}},product[12:0]})<<<15)+
    $signed({6'd0,blend_low_product});
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
// 任意十九位幅度下的最大对数输入为 52685，十六位足够且不改变取整。
wire [15:0] log_argument=16'd256+(({1'b0,reference_m_q8}+20'd5)/20'd10);
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
    input [15:0] argument;
    integer bit_index;
    reg [3:0] msb;
    reg [15:0] normalized;
    reg [9:0] result;
    begin
        msb=0;
        for(bit_index=0;bit_index<16;bit_index=bit_index+1)
            if(argument[bit_index]) msb=bit_index;
        normalized=argument>>(msb-6);
        // 输入范围 256..52685：原常数乘加含加8舍入的八个精确结果。
        case(msb)
            4'd8: result=10'd0;
            4'd9: result=10'd69;
            4'd10: result=10'd139;
            4'd11: result=10'd208;
            4'd12: result=10'd277;
            4'd13: result=10'd347;
            4'd14: result=10'd416;
            4'd15: result=10'd485;
            default: result=10'd0;
        endcase
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
(* rom_style="bram" *) reg [14:0] twiddle_quarter [0:511];
initial begin
    twiddle_quarter[0] = 15'h0000;
    twiddle_quarter[1] = 15'h0065;
    twiddle_quarter[2] = 15'h00c9;
    twiddle_quarter[3] = 15'h012e;
    twiddle_quarter[4] = 15'h0192;
    twiddle_quarter[5] = 15'h01f7;
    twiddle_quarter[6] = 15'h025b;
    twiddle_quarter[7] = 15'h02c0;
    twiddle_quarter[8] = 15'h0324;
    twiddle_quarter[9] = 15'h0389;
    twiddle_quarter[10] = 15'h03ed;
    twiddle_quarter[11] = 15'h0452;
    twiddle_quarter[12] = 15'h04b6;
    twiddle_quarter[13] = 15'h051b;
    twiddle_quarter[14] = 15'h057f;
    twiddle_quarter[15] = 15'h05e3;
    twiddle_quarter[16] = 15'h0648;
    twiddle_quarter[17] = 15'h06ac;
    twiddle_quarter[18] = 15'h0711;
    twiddle_quarter[19] = 15'h0775;
    twiddle_quarter[20] = 15'h07d9;
    twiddle_quarter[21] = 15'h083e;
    twiddle_quarter[22] = 15'h08a2;
    twiddle_quarter[23] = 15'h0906;
    twiddle_quarter[24] = 15'h096a;
    twiddle_quarter[25] = 15'h09cf;
    twiddle_quarter[26] = 15'h0a33;
    twiddle_quarter[27] = 15'h0a97;
    twiddle_quarter[28] = 15'h0afb;
    twiddle_quarter[29] = 15'h0b5f;
    twiddle_quarter[30] = 15'h0bc4;
    twiddle_quarter[31] = 15'h0c28;
    twiddle_quarter[32] = 15'h0c8c;
    twiddle_quarter[33] = 15'h0cf0;
    twiddle_quarter[34] = 15'h0d54;
    twiddle_quarter[35] = 15'h0db8;
    twiddle_quarter[36] = 15'h0e1c;
    twiddle_quarter[37] = 15'h0e80;
    twiddle_quarter[38] = 15'h0ee3;
    twiddle_quarter[39] = 15'h0f47;
    twiddle_quarter[40] = 15'h0fab;
    twiddle_quarter[41] = 15'h100f;
    twiddle_quarter[42] = 15'h1072;
    twiddle_quarter[43] = 15'h10d6;
    twiddle_quarter[44] = 15'h113a;
    twiddle_quarter[45] = 15'h119d;
    twiddle_quarter[46] = 15'h1201;
    twiddle_quarter[47] = 15'h1264;
    twiddle_quarter[48] = 15'h12c8;
    twiddle_quarter[49] = 15'h132b;
    twiddle_quarter[50] = 15'h138f;
    twiddle_quarter[51] = 15'h13f2;
    twiddle_quarter[52] = 15'h1455;
    twiddle_quarter[53] = 15'h14b9;
    twiddle_quarter[54] = 15'h151c;
    twiddle_quarter[55] = 15'h157f;
    twiddle_quarter[56] = 15'h15e2;
    twiddle_quarter[57] = 15'h1645;
    twiddle_quarter[58] = 15'h16a8;
    twiddle_quarter[59] = 15'h170b;
    twiddle_quarter[60] = 15'h176e;
    twiddle_quarter[61] = 15'h17d0;
    twiddle_quarter[62] = 15'h1833;
    twiddle_quarter[63] = 15'h1896;
    twiddle_quarter[64] = 15'h18f9;
    twiddle_quarter[65] = 15'h195b;
    twiddle_quarter[66] = 15'h19be;
    twiddle_quarter[67] = 15'h1a20;
    twiddle_quarter[68] = 15'h1a82;
    twiddle_quarter[69] = 15'h1ae5;
    twiddle_quarter[70] = 15'h1b47;
    twiddle_quarter[71] = 15'h1ba9;
    twiddle_quarter[72] = 15'h1c0b;
    twiddle_quarter[73] = 15'h1c6d;
    twiddle_quarter[74] = 15'h1ccf;
    twiddle_quarter[75] = 15'h1d31;
    twiddle_quarter[76] = 15'h1d93;
    twiddle_quarter[77] = 15'h1df5;
    twiddle_quarter[78] = 15'h1e57;
    twiddle_quarter[79] = 15'h1eb8;
    twiddle_quarter[80] = 15'h1f1a;
    twiddle_quarter[81] = 15'h1f7b;
    twiddle_quarter[82] = 15'h1fdd;
    twiddle_quarter[83] = 15'h203e;
    twiddle_quarter[84] = 15'h209f;
    twiddle_quarter[85] = 15'h2100;
    twiddle_quarter[86] = 15'h2161;
    twiddle_quarter[87] = 15'h21c2;
    twiddle_quarter[88] = 15'h2223;
    twiddle_quarter[89] = 15'h2284;
    twiddle_quarter[90] = 15'h22e5;
    twiddle_quarter[91] = 15'h2346;
    twiddle_quarter[92] = 15'h23a6;
    twiddle_quarter[93] = 15'h2407;
    twiddle_quarter[94] = 15'h2467;
    twiddle_quarter[95] = 15'h24c8;
    twiddle_quarter[96] = 15'h2528;
    twiddle_quarter[97] = 15'h2588;
    twiddle_quarter[98] = 15'h25e8;
    twiddle_quarter[99] = 15'h2648;
    twiddle_quarter[100] = 15'h26a8;
    twiddle_quarter[101] = 15'h2708;
    twiddle_quarter[102] = 15'h2767;
    twiddle_quarter[103] = 15'h27c7;
    twiddle_quarter[104] = 15'h2826;
    twiddle_quarter[105] = 15'h2886;
    twiddle_quarter[106] = 15'h28e5;
    twiddle_quarter[107] = 15'h2944;
    twiddle_quarter[108] = 15'h29a3;
    twiddle_quarter[109] = 15'h2a02;
    twiddle_quarter[110] = 15'h2a61;
    twiddle_quarter[111] = 15'h2ac0;
    twiddle_quarter[112] = 15'h2b1f;
    twiddle_quarter[113] = 15'h2b7d;
    twiddle_quarter[114] = 15'h2bdc;
    twiddle_quarter[115] = 15'h2c3a;
    twiddle_quarter[116] = 15'h2c99;
    twiddle_quarter[117] = 15'h2cf7;
    twiddle_quarter[118] = 15'h2d55;
    twiddle_quarter[119] = 15'h2db3;
    twiddle_quarter[120] = 15'h2e11;
    twiddle_quarter[121] = 15'h2e6e;
    twiddle_quarter[122] = 15'h2ecc;
    twiddle_quarter[123] = 15'h2f2a;
    twiddle_quarter[124] = 15'h2f87;
    twiddle_quarter[125] = 15'h2fe4;
    twiddle_quarter[126] = 15'h3041;
    twiddle_quarter[127] = 15'h309e;
    twiddle_quarter[128] = 15'h30fb;
    twiddle_quarter[129] = 15'h3158;
    twiddle_quarter[130] = 15'h31b5;
    twiddle_quarter[131] = 15'h3211;
    twiddle_quarter[132] = 15'h326e;
    twiddle_quarter[133] = 15'h32ca;
    twiddle_quarter[134] = 15'h3326;
    twiddle_quarter[135] = 15'h3383;
    twiddle_quarter[136] = 15'h33df;
    twiddle_quarter[137] = 15'h343a;
    twiddle_quarter[138] = 15'h3496;
    twiddle_quarter[139] = 15'h34f2;
    twiddle_quarter[140] = 15'h354d;
    twiddle_quarter[141] = 15'h35a8;
    twiddle_quarter[142] = 15'h3604;
    twiddle_quarter[143] = 15'h365f;
    twiddle_quarter[144] = 15'h36ba;
    twiddle_quarter[145] = 15'h3715;
    twiddle_quarter[146] = 15'h376f;
    twiddle_quarter[147] = 15'h37ca;
    twiddle_quarter[148] = 15'h3824;
    twiddle_quarter[149] = 15'h387e;
    twiddle_quarter[150] = 15'h38d9;
    twiddle_quarter[151] = 15'h3933;
    twiddle_quarter[152] = 15'h398c;
    twiddle_quarter[153] = 15'h39e6;
    twiddle_quarter[154] = 15'h3a40;
    twiddle_quarter[155] = 15'h3a99;
    twiddle_quarter[156] = 15'h3af2;
    twiddle_quarter[157] = 15'h3b4c;
    twiddle_quarter[158] = 15'h3ba5;
    twiddle_quarter[159] = 15'h3bfe;
    twiddle_quarter[160] = 15'h3c56;
    twiddle_quarter[161] = 15'h3caf;
    twiddle_quarter[162] = 15'h3d07;
    twiddle_quarter[163] = 15'h3d60;
    twiddle_quarter[164] = 15'h3db8;
    twiddle_quarter[165] = 15'h3e10;
    twiddle_quarter[166] = 15'h3e68;
    twiddle_quarter[167] = 15'h3ebf;
    twiddle_quarter[168] = 15'h3f17;
    twiddle_quarter[169] = 15'h3f6e;
    twiddle_quarter[170] = 15'h3fc5;
    twiddle_quarter[171] = 15'h401d;
    twiddle_quarter[172] = 15'h4073;
    twiddle_quarter[173] = 15'h40ca;
    twiddle_quarter[174] = 15'h4121;
    twiddle_quarter[175] = 15'h4177;
    twiddle_quarter[176] = 15'h41ce;
    twiddle_quarter[177] = 15'h4224;
    twiddle_quarter[178] = 15'h427a;
    twiddle_quarter[179] = 15'h42d0;
    twiddle_quarter[180] = 15'h4325;
    twiddle_quarter[181] = 15'h437b;
    twiddle_quarter[182] = 15'h43d0;
    twiddle_quarter[183] = 15'h4425;
    twiddle_quarter[184] = 15'h447a;
    twiddle_quarter[185] = 15'h44cf;
    twiddle_quarter[186] = 15'h4524;
    twiddle_quarter[187] = 15'h4578;
    twiddle_quarter[188] = 15'h45cd;
    twiddle_quarter[189] = 15'h4621;
    twiddle_quarter[190] = 15'h4675;
    twiddle_quarter[191] = 15'h46c9;
    twiddle_quarter[192] = 15'h471c;
    twiddle_quarter[193] = 15'h4770;
    twiddle_quarter[194] = 15'h47c3;
    twiddle_quarter[195] = 15'h4816;
    twiddle_quarter[196] = 15'h4869;
    twiddle_quarter[197] = 15'h48bc;
    twiddle_quarter[198] = 15'h490f;
    twiddle_quarter[199] = 15'h4961;
    twiddle_quarter[200] = 15'h49b4;
    twiddle_quarter[201] = 15'h4a06;
    twiddle_quarter[202] = 15'h4a58;
    twiddle_quarter[203] = 15'h4aa9;
    twiddle_quarter[204] = 15'h4afb;
    twiddle_quarter[205] = 15'h4b4c;
    twiddle_quarter[206] = 15'h4b9d;
    twiddle_quarter[207] = 15'h4bee;
    twiddle_quarter[208] = 15'h4c3f;
    twiddle_quarter[209] = 15'h4c90;
    twiddle_quarter[210] = 15'h4ce0;
    twiddle_quarter[211] = 15'h4d31;
    twiddle_quarter[212] = 15'h4d81;
    twiddle_quarter[213] = 15'h4dd1;
    twiddle_quarter[214] = 15'h4e20;
    twiddle_quarter[215] = 15'h4e70;
    twiddle_quarter[216] = 15'h4ebf;
    twiddle_quarter[217] = 15'h4f0e;
    twiddle_quarter[218] = 15'h4f5d;
    twiddle_quarter[219] = 15'h4fac;
    twiddle_quarter[220] = 15'h4ffb;
    twiddle_quarter[221] = 15'h5049;
    twiddle_quarter[222] = 15'h5097;
    twiddle_quarter[223] = 15'h50e5;
    twiddle_quarter[224] = 15'h5133;
    twiddle_quarter[225] = 15'h5181;
    twiddle_quarter[226] = 15'h51ce;
    twiddle_quarter[227] = 15'h521b;
    twiddle_quarter[228] = 15'h5268;
    twiddle_quarter[229] = 15'h52b5;
    twiddle_quarter[230] = 15'h5302;
    twiddle_quarter[231] = 15'h534e;
    twiddle_quarter[232] = 15'h539b;
    twiddle_quarter[233] = 15'h53e7;
    twiddle_quarter[234] = 15'h5432;
    twiddle_quarter[235] = 15'h547e;
    twiddle_quarter[236] = 15'h54c9;
    twiddle_quarter[237] = 15'h5515;
    twiddle_quarter[238] = 15'h5560;
    twiddle_quarter[239] = 15'h55aa;
    twiddle_quarter[240] = 15'h55f5;
    twiddle_quarter[241] = 15'h563f;
    twiddle_quarter[242] = 15'h568a;
    twiddle_quarter[243] = 15'h56d3;
    twiddle_quarter[244] = 15'h571d;
    twiddle_quarter[245] = 15'h5767;
    twiddle_quarter[246] = 15'h57b0;
    twiddle_quarter[247] = 15'h57f9;
    twiddle_quarter[248] = 15'h5842;
    twiddle_quarter[249] = 15'h588b;
    twiddle_quarter[250] = 15'h58d3;
    twiddle_quarter[251] = 15'h591c;
    twiddle_quarter[252] = 15'h5964;
    twiddle_quarter[253] = 15'h59ac;
    twiddle_quarter[254] = 15'h59f3;
    twiddle_quarter[255] = 15'h5a3b;
    twiddle_quarter[256] = 15'h5a82;
    twiddle_quarter[257] = 15'h5ac9;
    twiddle_quarter[258] = 15'h5b0f;
    twiddle_quarter[259] = 15'h5b56;
    twiddle_quarter[260] = 15'h5b9c;
    twiddle_quarter[261] = 15'h5be2;
    twiddle_quarter[262] = 15'h5c28;
    twiddle_quarter[263] = 15'h5c6e;
    twiddle_quarter[264] = 15'h5cb3;
    twiddle_quarter[265] = 15'h5cf9;
    twiddle_quarter[266] = 15'h5d3e;
    twiddle_quarter[267] = 15'h5d82;
    twiddle_quarter[268] = 15'h5dc7;
    twiddle_quarter[269] = 15'h5e0b;
    twiddle_quarter[270] = 15'h5e4f;
    twiddle_quarter[271] = 15'h5e93;
    twiddle_quarter[272] = 15'h5ed7;
    twiddle_quarter[273] = 15'h5f1a;
    twiddle_quarter[274] = 15'h5f5d;
    twiddle_quarter[275] = 15'h5fa0;
    twiddle_quarter[276] = 15'h5fe3;
    twiddle_quarter[277] = 15'h6025;
    twiddle_quarter[278] = 15'h6068;
    twiddle_quarter[279] = 15'h60aa;
    twiddle_quarter[280] = 15'h60eb;
    twiddle_quarter[281] = 15'h612d;
    twiddle_quarter[282] = 15'h616e;
    twiddle_quarter[283] = 15'h61af;
    twiddle_quarter[284] = 15'h61f0;
    twiddle_quarter[285] = 15'h6231;
    twiddle_quarter[286] = 15'h6271;
    twiddle_quarter[287] = 15'h62b1;
    twiddle_quarter[288] = 15'h62f1;
    twiddle_quarter[289] = 15'h6331;
    twiddle_quarter[290] = 15'h6370;
    twiddle_quarter[291] = 15'h63af;
    twiddle_quarter[292] = 15'h63ee;
    twiddle_quarter[293] = 15'h642d;
    twiddle_quarter[294] = 15'h646c;
    twiddle_quarter[295] = 15'h64aa;
    twiddle_quarter[296] = 15'h64e8;
    twiddle_quarter[297] = 15'h6525;
    twiddle_quarter[298] = 15'h6563;
    twiddle_quarter[299] = 15'h65a0;
    twiddle_quarter[300] = 15'h65dd;
    twiddle_quarter[301] = 15'h661a;
    twiddle_quarter[302] = 15'h6656;
    twiddle_quarter[303] = 15'h6693;
    twiddle_quarter[304] = 15'h66cf;
    twiddle_quarter[305] = 15'h670a;
    twiddle_quarter[306] = 15'h6746;
    twiddle_quarter[307] = 15'h6781;
    twiddle_quarter[308] = 15'h67bc;
    twiddle_quarter[309] = 15'h67f7;
    twiddle_quarter[310] = 15'h6832;
    twiddle_quarter[311] = 15'h686c;
    twiddle_quarter[312] = 15'h68a6;
    twiddle_quarter[313] = 15'h68e0;
    twiddle_quarter[314] = 15'h6919;
    twiddle_quarter[315] = 15'h6952;
    twiddle_quarter[316] = 15'h698b;
    twiddle_quarter[317] = 15'h69c4;
    twiddle_quarter[318] = 15'h69fd;
    twiddle_quarter[319] = 15'h6a35;
    twiddle_quarter[320] = 15'h6a6d;
    twiddle_quarter[321] = 15'h6aa4;
    twiddle_quarter[322] = 15'h6adc;
    twiddle_quarter[323] = 15'h6b13;
    twiddle_quarter[324] = 15'h6b4a;
    twiddle_quarter[325] = 15'h6b81;
    twiddle_quarter[326] = 15'h6bb7;
    twiddle_quarter[327] = 15'h6bed;
    twiddle_quarter[328] = 15'h6c23;
    twiddle_quarter[329] = 15'h6c59;
    twiddle_quarter[330] = 15'h6c8e;
    twiddle_quarter[331] = 15'h6cc3;
    twiddle_quarter[332] = 15'h6cf8;
    twiddle_quarter[333] = 15'h6d2d;
    twiddle_quarter[334] = 15'h6d61;
    twiddle_quarter[335] = 15'h6d95;
    twiddle_quarter[336] = 15'h6dc9;
    twiddle_quarter[337] = 15'h6dfd;
    twiddle_quarter[338] = 15'h6e30;
    twiddle_quarter[339] = 15'h6e63;
    twiddle_quarter[340] = 15'h6e96;
    twiddle_quarter[341] = 15'h6ec8;
    twiddle_quarter[342] = 15'h6efb;
    twiddle_quarter[343] = 15'h6f2c;
    twiddle_quarter[344] = 15'h6f5e;
    twiddle_quarter[345] = 15'h6f90;
    twiddle_quarter[346] = 15'h6fc1;
    twiddle_quarter[347] = 15'h6ff2;
    twiddle_quarter[348] = 15'h7022;
    twiddle_quarter[349] = 15'h7053;
    twiddle_quarter[350] = 15'h7083;
    twiddle_quarter[351] = 15'h70b2;
    twiddle_quarter[352] = 15'h70e2;
    twiddle_quarter[353] = 15'h7111;
    twiddle_quarter[354] = 15'h7140;
    twiddle_quarter[355] = 15'h716f;
    twiddle_quarter[356] = 15'h719d;
    twiddle_quarter[357] = 15'h71cb;
    twiddle_quarter[358] = 15'h71f9;
    twiddle_quarter[359] = 15'h7227;
    twiddle_quarter[360] = 15'h7254;
    twiddle_quarter[361] = 15'h7281;
    twiddle_quarter[362] = 15'h72ae;
    twiddle_quarter[363] = 15'h72db;
    twiddle_quarter[364] = 15'h7307;
    twiddle_quarter[365] = 15'h7333;
    twiddle_quarter[366] = 15'h735e;
    twiddle_quarter[367] = 15'h738a;
    twiddle_quarter[368] = 15'h73b5;
    twiddle_quarter[369] = 15'h73e0;
    twiddle_quarter[370] = 15'h740a;
    twiddle_quarter[371] = 15'h7435;
    twiddle_quarter[372] = 15'h745f;
    twiddle_quarter[373] = 15'h7488;
    twiddle_quarter[374] = 15'h74b2;
    twiddle_quarter[375] = 15'h74db;
    twiddle_quarter[376] = 15'h7504;
    twiddle_quarter[377] = 15'h752d;
    twiddle_quarter[378] = 15'h7555;
    twiddle_quarter[379] = 15'h757d;
    twiddle_quarter[380] = 15'h75a5;
    twiddle_quarter[381] = 15'h75cc;
    twiddle_quarter[382] = 15'h75f3;
    twiddle_quarter[383] = 15'h761a;
    twiddle_quarter[384] = 15'h7641;
    twiddle_quarter[385] = 15'h7667;
    twiddle_quarter[386] = 15'h768d;
    twiddle_quarter[387] = 15'h76b3;
    twiddle_quarter[388] = 15'h76d8;
    twiddle_quarter[389] = 15'h76fe;
    twiddle_quarter[390] = 15'h7722;
    twiddle_quarter[391] = 15'h7747;
    twiddle_quarter[392] = 15'h776b;
    twiddle_quarter[393] = 15'h778f;
    twiddle_quarter[394] = 15'h77b3;
    twiddle_quarter[395] = 15'h77d7;
    twiddle_quarter[396] = 15'h77fa;
    twiddle_quarter[397] = 15'h781d;
    twiddle_quarter[398] = 15'h783f;
    twiddle_quarter[399] = 15'h7862;
    twiddle_quarter[400] = 15'h7884;
    twiddle_quarter[401] = 15'h78a5;
    twiddle_quarter[402] = 15'h78c7;
    twiddle_quarter[403] = 15'h78e8;
    twiddle_quarter[404] = 15'h7909;
    twiddle_quarter[405] = 15'h7929;
    twiddle_quarter[406] = 15'h794a;
    twiddle_quarter[407] = 15'h796a;
    twiddle_quarter[408] = 15'h7989;
    twiddle_quarter[409] = 15'h79a9;
    twiddle_quarter[410] = 15'h79c8;
    twiddle_quarter[411] = 15'h79e6;
    twiddle_quarter[412] = 15'h7a05;
    twiddle_quarter[413] = 15'h7a23;
    twiddle_quarter[414] = 15'h7a41;
    twiddle_quarter[415] = 15'h7a5f;
    twiddle_quarter[416] = 15'h7a7c;
    twiddle_quarter[417] = 15'h7a99;
    twiddle_quarter[418] = 15'h7ab6;
    twiddle_quarter[419] = 15'h7ad2;
    twiddle_quarter[420] = 15'h7aee;
    twiddle_quarter[421] = 15'h7b0a;
    twiddle_quarter[422] = 15'h7b26;
    twiddle_quarter[423] = 15'h7b41;
    twiddle_quarter[424] = 15'h7b5c;
    twiddle_quarter[425] = 15'h7b77;
    twiddle_quarter[426] = 15'h7b91;
    twiddle_quarter[427] = 15'h7bab;
    twiddle_quarter[428] = 15'h7bc5;
    twiddle_quarter[429] = 15'h7bde;
    twiddle_quarter[430] = 15'h7bf8;
    twiddle_quarter[431] = 15'h7c10;
    twiddle_quarter[432] = 15'h7c29;
    twiddle_quarter[433] = 15'h7c41;
    twiddle_quarter[434] = 15'h7c59;
    twiddle_quarter[435] = 15'h7c71;
    twiddle_quarter[436] = 15'h7c88;
    twiddle_quarter[437] = 15'h7c9f;
    twiddle_quarter[438] = 15'h7cb6;
    twiddle_quarter[439] = 15'h7ccd;
    twiddle_quarter[440] = 15'h7ce3;
    twiddle_quarter[441] = 15'h7cf9;
    twiddle_quarter[442] = 15'h7d0e;
    twiddle_quarter[443] = 15'h7d24;
    twiddle_quarter[444] = 15'h7d39;
    twiddle_quarter[445] = 15'h7d4d;
    twiddle_quarter[446] = 15'h7d62;
    twiddle_quarter[447] = 15'h7d76;
    twiddle_quarter[448] = 15'h7d89;
    twiddle_quarter[449] = 15'h7d9d;
    twiddle_quarter[450] = 15'h7db0;
    twiddle_quarter[451] = 15'h7dc3;
    twiddle_quarter[452] = 15'h7dd5;
    twiddle_quarter[453] = 15'h7de8;
    twiddle_quarter[454] = 15'h7dfa;
    twiddle_quarter[455] = 15'h7e0b;
    twiddle_quarter[456] = 15'h7e1d;
    twiddle_quarter[457] = 15'h7e2e;
    twiddle_quarter[458] = 15'h7e3e;
    twiddle_quarter[459] = 15'h7e4f;
    twiddle_quarter[460] = 15'h7e5f;
    twiddle_quarter[461] = 15'h7e6f;
    twiddle_quarter[462] = 15'h7e7e;
    twiddle_quarter[463] = 15'h7e8d;
    twiddle_quarter[464] = 15'h7e9c;
    twiddle_quarter[465] = 15'h7eab;
    twiddle_quarter[466] = 15'h7eb9;
    twiddle_quarter[467] = 15'h7ec7;
    twiddle_quarter[468] = 15'h7ed5;
    twiddle_quarter[469] = 15'h7ee2;
    twiddle_quarter[470] = 15'h7eef;
    twiddle_quarter[471] = 15'h7efc;
    twiddle_quarter[472] = 15'h7f09;
    twiddle_quarter[473] = 15'h7f15;
    twiddle_quarter[474] = 15'h7f21;
    twiddle_quarter[475] = 15'h7f2c;
    twiddle_quarter[476] = 15'h7f37;
    twiddle_quarter[477] = 15'h7f42;
    twiddle_quarter[478] = 15'h7f4d;
    twiddle_quarter[479] = 15'h7f57;
    twiddle_quarter[480] = 15'h7f61;
    twiddle_quarter[481] = 15'h7f6b;
    twiddle_quarter[482] = 15'h7f74;
    twiddle_quarter[483] = 15'h7f7d;
    twiddle_quarter[484] = 15'h7f86;
    twiddle_quarter[485] = 15'h7f8f;
    twiddle_quarter[486] = 15'h7f97;
    twiddle_quarter[487] = 15'h7f9f;
    twiddle_quarter[488] = 15'h7fa6;
    twiddle_quarter[489] = 15'h7fad;
    twiddle_quarter[490] = 15'h7fb4;
    twiddle_quarter[491] = 15'h7fbb;
    twiddle_quarter[492] = 15'h7fc1;
    twiddle_quarter[493] = 15'h7fc7;
    twiddle_quarter[494] = 15'h7fcd;
    twiddle_quarter[495] = 15'h7fd2;
    twiddle_quarter[496] = 15'h7fd8;
    twiddle_quarter[497] = 15'h7fdc;
    twiddle_quarter[498] = 15'h7fe1;
    twiddle_quarter[499] = 15'h7fe5;
    twiddle_quarter[500] = 15'h7fe9;
    twiddle_quarter[501] = 15'h7fec;
    twiddle_quarter[502] = 15'h7ff0;
    twiddle_quarter[503] = 15'h7ff3;
    twiddle_quarter[504] = 15'h7ff5;
    twiddle_quarter[505] = 15'h7ff7;
    twiddle_quarter[506] = 15'h7ff9;
    twiddle_quarter[507] = 15'h7ffb;
    twiddle_quarter[508] = 15'h7ffd;
    twiddle_quarter[509] = 15'h7ffe;
    twiddle_quarter[510] = 15'h7ffe;
    twiddle_quarter[511] = 15'h7fff;
end
// 两个既有取数周期复用单读口 ROM，恢复原 1024 项的精确符号与端点。
reg [14:0] twiddle_quarter_q,twiddle_real_abs,twiddle_imag_abs;
reg [9:0] twiddle_index_q;
wire [8:0] twiddle_fold=9'd0-twiddle_index[8:0];
wire [8:0] twiddle_real_address=twiddle_index[9]?twiddle_index[8:0]:twiddle_fold;
wire [8:0] twiddle_imag_address=twiddle_index[9]?twiddle_fold:twiddle_index[8:0];
always @(posedge clk) begin
    if (state==ST_RD_B) begin
        twiddle_real_abs<=twiddle_quarter_q;
    end
    if (state==ST_LATCH_B) begin
        twiddle_imag_abs<=twiddle_quarter_q;twiddle_index_q<=twiddle_index;
    end
    if (state==ST_LATCH_A || state==ST_RD_B)
        twiddle_quarter_q<=twiddle_quarter[(state==ST_LATCH_A)?twiddle_real_address:twiddle_imag_address];
end
wire [15:0] twiddle_real_value=(!twiddle_index_q[9] && twiddle_index_q[8:0]==0)?16'h7fff:{1'b0,twiddle_real_abs};
wire [15:0] twiddle_imag_value=(twiddle_index_q[9] && twiddle_index_q[8:0]==0)?16'h7fff:{1'b0,twiddle_imag_abs};
assign twiddle_word={(twiddle_index_q[9]?16'd0-twiddle_real_value:twiddle_real_value),16'd0-twiddle_imag_value};
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

// 后台在构建开始时撤销待发布标志，构建中不会切换前台银行。
// 发布沿同步读仍取旧前台，与渲染器该沿锁存的旧半径一致。
generate if(BLOCK_BARS)begin: block_bars
    reg front_bank,published_valid,read_valid;
    reg build_nonzero,published_nonzero;
    wire [7:0] cache_q;
    wire publish=frame_start && !frame_start_d && pending_valid;
    rhythm_block_ram #(.IMPLEMENT("9K"),.WIDTH(8),.ADDRESS_BITS(8),.DEPTH(256)) cache(
        .write_clk(clk),.write_enable(!rst && state==ST_BAR_WRITE),
        .write_address({!front_bank,bar_index}),.write_data(bar_level),
        .read_clk(clk),.read_address({front_bank,bars_read_address}),.read_data(cache_q));
    assign bars=640'd0;
    assign bars_build=640'd0;
    assign bars_read_valid=read_valid;
    assign bars_read_data=read_valid ? cache_q : 8'd0;
    assign bars_active=published_nonzero;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            front_bank<=1'b0;published_valid<=1'b0;read_valid<=1'b0;
            build_nonzero<=1'b0;published_nonzero<=1'b0;
        end else begin
            read_valid<=published_valid && bars_read_address<7'd80;
            if(publish)begin
                front_bank<=!front_bank;published_valid<=1'b1;
                published_nonzero<=build_nonzero;
            end
            // 第一柱覆盖累计值；无需额外解码幅度扫描末项，待发布标志隔离构建间隙。
            if(state==ST_BAR_WRITE)build_nonzero<=bar_index==7'd0 ? (|bar_level) : build_nonzero || (|bar_level);
        end
    end
end else begin: wide_bars
    reg [639:0] front,back;
    assign bars=front;
    assign bars_build=back;
    assign bars_read_data=8'd0;
    assign bars_read_valid=1'b0;
    assign bars_active=|front;
    always @(posedge clk or posedge rst)begin
        if(rst)begin front<=640'd0;back<=640'd0;end
        else begin
            if(frame_start && !frame_start_d && pending_valid)front<=back;
            if(state==ST_BAR_WRITE)back<={bar_level,back[639:8]};
        end
    end
end endgenerate

always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=ST_INIT;scan_bin<=0;sample_count<=0;capture_bank<=0;process_bank<=0;
        group_base<=0;pair_index<=0;step<=1;stage<=0;
        pending_valid<=0;frame_start_d<=0;
        breath_radius<=8'd90;radius_build<=8'd90;raw_peak<=0;peak_envelope<=0;
        bar_index<=0;sqrt_count<=0;sqrt_root<=0;sqrt_remainder<=0;square_sum<=0;
        a_data<=0;b_data<=0;p0<=0;p1<=0;p2<=0;p3<=0;
        result_a<=0;result_b<=0;magnitude_a<=0;magnitude_b<=0;
        interpolated_product<=0;blend_high<=0;blend_low_product<=0;bar_level<=0;
    end else begin
        frame_start_d<=frame_start;
        // build 只在完整生成 80 柱后有效；开始下一次构建时撤销有效标志。
        // 避免使用第三组 640 位寄存器，也不会发布正在改写的半帧数据。
        if(frame_start && !frame_start_d && pending_valid) begin
            breath_radius<=radius_build;pending_valid<=0;
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
            ST_BAR_B: begin
                magnitude_b<=history_q[18:0];
                blend_high<=blend_difference[19:15];blend_low_product<=product[22:0];
                state<=ST_BLEND;
            end
            ST_BLEND: begin
                // 幅度先线性插值，再对数压缩，避免先压缩后插值产生错误轮廓。
                interpolated_product<=blend_reconstructed[26:0];
                state<=ST_LOG;
            end
            ST_LOG: begin bar_level<=reference_level(log_argument);state<=ST_BAR_WRITE;end
            ST_BAR_WRITE: begin
                // 缓存写入与本拍索引对应；最后一柱写完后才允许帧发布。
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
