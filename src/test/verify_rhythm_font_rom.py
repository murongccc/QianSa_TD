"""导出综合网表并核对 1024 个字库 ROM 初始化地址，不生成 bitstream。"""
import argparse
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, default=Path('prj/log/rhythm_stage4_release_syn'))
    parser.add_argument('--td', default='E:/AnLuTD/bin/td_commands_prompt.exe')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = (root / args.build).resolve()
    (build / 'check_rom.tcl').write_text(
        'import_device eagle_s20.db -package EG4S20BG256\n'
        'open_project SD_to_Video.prj -noanalyze\n'
        'import_db SD_to_Video_gate.db\nwrite_verilog mapped_check.v\nexit\n')
    netlist = build / 'mapped_check.v'
    if netlist.exists():
        netlist.unlink()
    with (build / 'mapped_console.log').open('wb') as log:
        result = subprocess.run([args.td, 'check_rom.tcl'], cwd=build, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode or not netlist.exists():
        raise RuntimeError('mapped font export failed')
    text = netlist.read_text()
    block = text.split('// u_game_renderer/font/ramread0_syn_4_1024x5')[1].split('AL_MAP_LUT')[0]
    if 'EG_PHY_BRAM' not in block or '.DATA_WIDTH_A("9")' not in block:
        raise RuntimeError('font was not mapped to expected 1024x9 BRAM')
    init = {key: int(value, 16) for key, value in
            re.findall(r"\.(INIT_[0-9A-F]+)\(256'h([0-9A-F]+)\)", block)}
    packed = sum(init[f'INIT_{i:02X}'] << (256*i) for i in range(32))
    source = (root / 'src/rhythm_font.v').read_text(encoding='utf-8')
    glyphs = {int(code, 16): value for code, value in
              re.findall(r"8'h([0-9a-f]+):glyph=35'b([01]+);", source)}
    for address in range(1024):
        code, row = divmod(address, 8)
        expected = int(glyphs[code][row*5:row*5+5], 2) if code in glyphs and row < 7 else 0
        actual = (packed >> (8*address)) & 255
        if actual != expected:
            raise RuntimeError(f'font INIT mismatch at {address}: {actual} != {expected}')
    print(f'PASS mapped font ROM: 1024 exact entries, {len(glyphs)} glyphs; {build}')


if __name__ == '__main__':
    main()
