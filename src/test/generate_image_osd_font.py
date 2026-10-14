"""生成中文图片OSD的紧凑同步ROM；字形编号独立于Unicode编码。"""
from pathlib import Path
import argparse
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
HANZI = '输入分辨率出水平缩放垂直亮度对比'
ASCII = '0123456789×.%:/ ▶'

def make_font():
    chinese = ImageFont.truetype('C:/Windows/Fonts/simsun.ttc', 16)
    latin = ImageFont.truetype('C:/Windows/Fonts/consola.ttf', 14)
    data = [0] * 512
    preview = Image.new('RGB', (512, 72), '#202630')
    for chars, base, width, font in [(HANZI, 0, 16, chinese), (ASCII, 256, 8, latin)]:
        for index, char in enumerate(chars):
            tile = Image.new('1', (width, 16))
            draw = ImageDraw.Draw(tile)
            if char == '▶':
                draw.polygon([(1, 3), (6, 8), (1, 12)], fill=1)
            elif char != ' ':
                box = draw.textbbox((0, 0), char, font=font)
                baseline_box=box if width==16 else draw.textbbox((0,0),'0123456789',font=font)
                draw.text(((width-box[2]+box[0])//2-box[0], (16-baseline_box[3]+baseline_box[1])//2-baseline_box[1]), char, font=font, fill=1)
            # 中文16字+半角16字各占256行。三角标记由OSD几何逻辑绘制。
            if char != '▶':
                for row in range(16):
                    data[base+index*16+row] = sum(
                        int(tile.getpixel((col, row))) << (15-col) for col in range(width))
            px = index*24 if width == 16 else index*20
            preview.paste(tile.convert('RGB').resize((width, 16)), (px, 8 if width == 16 else 40))
    return data, preview

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args=parser.parse_args()
    data, preview=make_font()
    path=ROOT/'src/image_osd_font.v'
    body=''.join(f"        rows[9'd{i}]=16'h{x:04x};\n" for i,x in enumerate(data) if x)
    source=('// 中文16x16、数字符号8x16；512x16同步ROM，字符与行号直接拼接寻址。\n'
            '// 由src/test/generate_image_osd_font.py生成；仅此脚本维护字形表。\n'
            'module image_osd_font(input wire clk,input wire [8:0] address,output reg [15:0] bits);\n'
            'reg [15:0] rows[0:511];integer i;\ninitial begin\n'
            "    for(i=0;i<512;i=i+1)rows[i]=16'd0;\n"+body+
            'end\nalways @(posedge clk)bits<=rows[address];\nendmodule\n')
    if args.check:
        assert path.read_text(encoding='utf-8') == source, '字库需重新生成'
    else:
        path.write_text(source, encoding='utf-8')
    output=ROOT/'prj/log/image_osd_20261014'
    output.mkdir(parents=True, exist_ok=True)
    preview.save(output/'font_preview.png')
    print(f'PASS image font: {len(HANZI)} Chinese glyphs, {len(ASCII)} symbols, 1024 bytes')

if __name__ == '__main__':main()
