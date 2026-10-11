"""生成 80 柱圆环的定点角度、对数频率插值与彩虹查表。"""
import argparse
import colorsys
import math
import re
from pathlib import Path

ENDS = list(range(1, 17)) + [17, 19, 21, 24, 27, 30, 34, 38, 43, 48, 54, 60, 66, 70, 73, 75]
CENTERS = [(a + 1 + b) / 2 for a, b in zip([0] + ENDS[:-1], ENDS)]

def mapping(index):
    """返回频段索引、四分之一插值权重、虚拟零频标志。"""
    bin_position = 76 ** (min(index, 76) / 76) - 1
    if bin_position < 1:
        return 0, min(3, int(bin_position * 4 + .5)), 1
    for band in range(31):
        if bin_position < CENTERS[band + 1]:
            weight = int(4 * (bin_position - CENTERS[band]) /
                         (CENTERS[band + 1] - CENTERS[band]) + .5)
            if weight >= 4:
                return band + 1, 0, 0
            return band, weight, 0
    return 31, 0, 0

def shifts(value):
    terms = [f"(major_wide << {bit})" for bit in range(9) if value & (1 << bit)]
    return ' + '.join(terms) if terms else "16'd0"


def lookup_function(name, width, words):
    # 位平面常量选择强制使用逻辑多路器，避免组合 case 被推断成带时钟的 BRAM。
    result = [f'function [{width-1}:0] {name};', '    input [6:0] index;', '    begin']
    for bit in range(width):
        plane = sum(((word >> bit) & 1) << i for i, word in enumerate(words))
        result.append(f"        {name}[{bit}] = (80'h{plane:020x} >> index) & 1'b1;")
    return result + ['    end', 'endfunction']


def generate_tables():
    bounds = [round(256 * math.tan(math.pi * (i + .5) / 40)) for i in range(10)]
    centers = [round(256 * math.tan(math.pi * i / 40)) for i in range(11)]
    lines = ['// 此区由 src/test/generate_ring_visual_tables.py 生成；角度为 Q8 正切。']
    def multiply(name, coefficient):
        return [f'EG_LOGIC_MULT #(.INPUT_WIDTH_A(9),.INPUT_WIDTH_B(9),.OUTPUT_WIDTH(16),',
                '    .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),',
                f'    .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")) {name}_mul(',
                f"    .p({name}),.a({{1'b0,major}}),.b({coefficient}),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),",
                '    .clk(clk),.rstan(!rst),.rstbn(!rst),.rstpdn(!rst));']
    for i in range(10):
        lines.append(f'wire [15:0] bound{i};')
    lines.append('generate if(DSP_GEOMETRY)begin: dsp_bounds')
    for i, value in enumerate(bounds):
        lines += multiply(f'bound{i}', f"9'd{value}")
    lines.append('end else begin: lut_bounds')
    for i, value in enumerate(bounds):
        lines.append(f'assign bound{i} = {shifts(value)};')
    lines.append('end endgenerate')
    lines.append('wire [3:0] octant_position =')
    for i in range(10):
        lines.append(f"    (minor256 < bound{i}) ? 4'd{i} :")
    lines += ["    4'd10;", 'wire [15:0] axis_product;',
              'generate if(DSP_GEOMETRY)begin: dsp_axis', 'reg [8:0] coefficient;',
              'always @* case(octant_position)']
    for i, value in enumerate(centers):
        lines.append(f"    4'd{i}: coefficient=9'd{value};")
    lines += ["    default: coefficient=9'd256;", 'endcase']
    lines += multiply('axis_product', 'coefficient')
    lines += ['end else begin: lut_axis', 'reg [15:0] product;',
              'assign axis_product=product;', 'always @* begin', '    case (octant_position)']
    for i, value in enumerate(centers):
        lines.append(f"        4'd{i}: product = {shifts(value)};")
    lines += ["        default: product = major_wide << 8;", '    endcase', 'end', 'end endgenerate']
    words = []
    for i in range(80):
        band, weight, virtual = mapping(i)
        words.append((virtual << 7) | (band << 2) | weight)
    lines += lookup_function('visual_mapping', 8, words)
    words = []
    for i in range(80):
        rgb = colorsys.hsv_to_rgb((190 / 360 + i / 80) % 1, .65, 1)
        words.append(sum(round(c * 255) << shift for c, shift in zip(rgb, [16, 8, 0])))
    lines += lookup_function('rainbow', 24, words)
    return '\n'.join(lines) + '\n'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[1] / 'ring_spectrum_renderer.v'
    source = path.read_text(encoding='utf-8')
    start = source.index('// BEGIN GENERATED TABLES\n') + len('// BEGIN GENERATED TABLES\n')
    end = source.index('// END GENERATED TABLES', start)
    generated = generate_tables()
    if args.check:
        analyzer = (path.parent / 'audio_fft_spectrum.v').read_text(encoding='utf-8')
        band_table = analyzer.split('function [8:0] band_last;', 1)[1].split('end else begin', 1)[0]
        actual = [int(v) for v in re.findall(r"5'd\d+: band_last = 9'd(\d+);", band_table)]
        assert actual == ENDS, 'analyzer frequency table differs from renderer'
        reciprocal = analyzer.split('function [7:0] band_reciprocal;', 1)[1].split('end else begin', 1)[0]
        actual = [int(v) for v in re.findall(r"5'd\d+: band_reciprocal = 8'd(\d+);", reciprocal)]
        expected = [int(128 / (b-a) + .5) for a,b in zip([0]+ENDS[:-1], ENDS)]
        assert actual == expected, 'analyzer mean reciprocals differ from band widths'
        assert source[start:end] == generated, 'renderer tables need regeneration'
        print('PASS ring table reproducibility')
    else:
        path.write_text(source[:start] + generated + source[end:], encoding='utf-8')

if __name__ == '__main__':
    main()
