"""生成参考圆环的旋转因子、物理频率插值和自然对数定点表。"""
import argparse
import math
from pathlib import Path


def tables():
    lines = ["// 由 generate_reference_fft_tables.py 生成；同步块 ROM 不依赖外部初始化文件。"]
    # 正弦四分之一周期；512 端点为 32767，单独处理，ROM 恰好 512×15。
    lines += ['(* rom_style="bram" *) reg [14:0] twiddle_quarter [0:511];', 'initial begin']
    for i in range(512):
        value = round(32767 * math.sin(2 * math.pi * i / 2048))
        lines.append(f"    twiddle_quarter[{i}] = 15'h{value:04x};")
    lines += ['end', '// 两个既有取数周期复用单读口 ROM，恢复原 1024 项的精确符号与端点。',
              'reg [14:0] twiddle_quarter_q,twiddle_real_abs,twiddle_imag_abs;', 'reg [9:0] twiddle_index_q;',
              "wire [8:0] twiddle_fold=9'd0-twiddle_index[8:0];",
              'wire [8:0] twiddle_real_address=twiddle_index[9]?twiddle_index[8:0]:twiddle_fold;',
              'wire [8:0] twiddle_imag_address=twiddle_index[9]?twiddle_fold:twiddle_index[8:0];',
              'always @(posedge clk) begin', '    if (state==ST_RD_B) begin',
              '        twiddle_real_abs<=twiddle_quarter_q;', '    end',
              '    if (state==ST_LATCH_B) begin',
              '        twiddle_imag_abs<=twiddle_quarter_q;twiddle_index_q<=twiddle_index;', '    end',
              '    if (state==ST_LATCH_A || state==ST_RD_B)',
              '        twiddle_quarter_q<=twiddle_quarter[(state==ST_LATCH_A)?twiddle_real_address:twiddle_imag_address];',
              'end',
              "wire [15:0] twiddle_real_value=(!twiddle_index_q[9] && twiddle_index_q[8:0]==0)?16'h7fff:{1'b0,twiddle_real_abs};",
              "wire [15:0] twiddle_imag_value=(twiddle_index_q[9] && twiddle_index_q[8:0]==0)?16'h7fff:{1'b0,twiddle_imag_abs};",
              "assign twiddle_word={(twiddle_index_q[9]?16'd0-twiddle_real_value:twiddle_real_value),16'd0-twiddle_imag_value};"]
    # 参考圆环每四个屏幕横坐标取一柱：bin=320^(i/80)-1。
    # 转换为 48 kHz、2048 点的 Q8 坐标，兼容 512/1024 时按比例右移。
    words = [round((320 ** (i / 80) - 1) * 44100 / 48000 * 256) for i in range(80)]
    lines += ["function [16:0] reference_position;", "    input [6:0] index;", "    begin"]
    for b in range(17):
        plane = sum(((v >> b) & 1) << i for i, v in enumerate(words))
        lines.append(f"        reference_position[{b}] = (80'h{plane:020x} >> index) & 1'b1;")
    lines += ["    end", "endfunction", "function [7:0] reference_log_fraction;", "    input [5:0] index;", "    begin", "        case (index)"]
    for i in range(64):
        lines.append(f"            6'd{i}: reference_log_fraction = 8'd{round(100 * math.log(1+i/64))};")
    lines += ["            default: reference_log_fraction = 8'd0;", "        endcase", "    end", "endfunction"]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[1] / "audio_fft_spectrum.v"
    source = path.read_text(encoding="utf-8")
    start = source.index("// BEGIN REFERENCE TABLES\n") + len("// BEGIN REFERENCE TABLES\n")
    end = source.index("// END REFERENCE TABLES", start)
    if args.check:
        assert source[start:end] == tables()
        print("PASS reference FFT table reproducibility")
    else:
        path.write_text(source[:start] + tables() + source[end:], encoding="utf-8")


if __name__ == "__main__":
    main()
