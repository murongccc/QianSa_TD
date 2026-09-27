"""生成参考圆环的旋转因子、物理频率插值和自然对数定点表。"""
import argparse
import math
from pathlib import Path


def tables():
    lines = ["// 由 generate_reference_fft_tables.py 生成，不使用外部 ROM 文件。"]
    lines += ["function [31:0] reference_twiddle;", "    input [8:0] index;", "    begin", "        case (index)"]
    for i in range(512):
        r = round(32767 * math.cos(2 * math.pi * i / 1024)) & 65535
        j = round(-32767 * math.sin(2 * math.pi * i / 1024)) & 65535
        lines.append(f"            9'd{i}: reference_twiddle = 32'h{r:04x}{j:04x};")
    lines += ["            default: reference_twiddle = 32'h7fff0000;", "        endcase", "    end", "endfunction"]
    # 参考圆环每四个屏幕横坐标取一柱：bin=320^(i/80)-1。
    # 转换为 48 kHz 下的物理频点；1024 表的 Q8 坐标右移一位即 512 表。
    words = [round((320 ** (i / 80) - 1) * 44100 / 2048 * 1024 / 48000 * 256) for i in range(80)]
    lines += ["function [15:0] reference_position;", "    input [6:0] index;", "    begin"]
    for b in range(16):
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
