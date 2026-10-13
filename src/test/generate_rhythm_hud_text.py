"""生成 HUD 同步静态文字 ROM；地址布局固定，未使用地址为空格。"""
import argparse
from pathlib import Path


def words():
    result = [32] * 1024
    labels = {32: 'COMBO', 128: 'E', 144: 'P', 160: 'G', 176: 'B', 192: 'M', 208: 'C'}
    for mode, text in enumerate(['MANUAL']):
        for address, label in {**labels, 48: text}.items():
            result[mode*256+address:mode*256+address+len(label)] = label.encode('ascii')
    statuses = {2: 'STOP - SW1 START', 4: 'LOADING', 5: 'READY', 7: 'PAUSED',
                8: 'BUFFERING', 10: 'RESULT', 11: 'ERROR'}
    for state, text in statuses.items():
        result[512+state*16:512+state*16+16] = text.ljust(16).encode('ascii')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[1] / 'rhythm_hud.v'
    source = path.read_text(encoding='utf-8')
    start = source.index('// BEGIN HUD TEXT ROM\n') + len('// BEGIN HUD TEXT ROM\n')
    end = source.index('// END HUD TEXT ROM', start)
    table = ''.join(f"            text_rom[{address}]=8'h{value:02x};\n"
                    for address, value in enumerate(words()) if value != 32)
    if args.check:
        assert source[start:end] == table, 'HUD text table needs regeneration'
        print('PASS HUD text table: 1024 words')
    else:
        path.write_text(source[:start]+table+source[end:], encoding='utf-8')


if __name__ == '__main__':
    main()
