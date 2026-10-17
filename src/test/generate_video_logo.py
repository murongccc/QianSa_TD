"""将原始透明 PNG 双线性缩小为 56x36，生成呈现模块内的 4 位索引 ROM。"""
from pathlib import Path
import argparse
import shutil
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
ASSET = ROOT / 'src/assets/logo_source.png'
BEGIN = '// BEGIN VIDEO LOGO ROM'
END = '// END VIDEO LOGO ROM'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, help='首次导入或主动更新原图')
    args = parser.parse_args()
    ASSET.parent.mkdir(parents=True, exist_ok=True)
    if args.source:
        shutil.copyfile(args.source, ASSET)
    source = Image.open(ASSET).convert('RGBA')
    box = source.getchannel('A').getbbox()
    if box is None:
        raise ValueError('Logo alpha channel is empty')
    image = source.crop(box).resize((56, 36), Image.Resampling.BILINEAR)
    # 原图已有透明通道，保留深蓝主体；透明索引与黑色 RGB 值无关。
    quantized = image.convert('RGB').quantize(colors=15, dither=Image.Dither.NONE)
    palette = quantized.getpalette()
    indices = [quantized.getpixel((x, y)) + 1 if image.getpixel((x, y))[3] >= 128 else 0
               for y in range(36) for x in range(56)]
    colors = [(0, 0, 0)] + [tuple(palette[i * 3:i * 3 + 3]) for i in range(15)]
    lines = [BEGIN,
             '// 固定56x36；索引0透明。2048x4同步ROM，匹配呈现第一级，不增加视频延迟。',
             '// 由src/test/generate_video_logo.py生成；原图保存在src/assets/logo_source.png。',
             'reg [3:0] logo_pixels[0:2047];',
             'integer logo_i,logo_j;',
             'function [223:0] logo_row;',
             '    input integer row;',
             '    begin', '        case(row)']
    for y in range(36):
        data = ''.join(format(i, 'x') for i in indices[y * 56:(y + 1) * 56])
        lines.append(f"            {y}:logo_row=224'h{data};")
    lines += ["            default:logo_row=224'd0;", '        endcase', '    end', 'endfunction',
              'initial begin', "    for(logo_i=0;logo_i<2048;logo_i=logo_i+1)logo_pixels[logo_i]=4'd0;",
              '    for(logo_i=0;logo_i<36;logo_i=logo_i+1)',
              '        for(logo_j=0;logo_j<56;logo_j=logo_j+1)',
              '            logo_pixels[logo_i*56+logo_j]=logo_row(logo_i)>>((55-logo_j)*4);',
              'end', 'function [23:0] logo_color;', '    input [3:0] index;',
              '    begin', '        case(index)']
    for index, color in enumerate(colors):
        lines.append(f"            4'd{index}:logo_color=24'h{bytes(color).hex()};")
    lines += ["            default:logo_color=24'd0;", '        endcase', '    end', 'endfunction', END]
    path = ROOT / 'src/video_presentation.v'
    text = path.read_text(encoding='utf-8')
    start, finish = text.index(BEGIN), text.index(END) + len(END)
    path.write_text(text[:start] + '\n'.join(lines) + text[finish:], encoding='utf-8')
    preview = Image.new('RGBA', (56, 36))
    preview.putdata([(*colors[i], 255 if i else 0) for i in indices])
    preview.save(ROOT / 'src/assets/logo_56x36.png')
    out = ROOT / 'prj/log/video_logo_20261017'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'expected.hex').write_text('\n'.join(f'{int(i != 0):x}{bytes(colors[i]).hex()}' for i in indices) + '\n')
    print(f'PASS logo generated: crop={box}, size=56x36, opaque={sum(i != 0 for i in indices)}, ROM=8192 bits')


if __name__ == '__main__':
    main()
