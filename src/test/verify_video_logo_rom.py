"""导出TD综合网表，逐字确认Logo确实映射为带初始化的单片BRAM9K。"""
from pathlib import Path
import argparse
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, default=Path('prj/log/video_logo_syn_20261017'))
    parser.add_argument('--td', default='E:/AnLuTD/bin/td_commands_prompt.exe')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = (root / args.build).resolve()
    script = build / 'check_logo.tcl'
    script.write_text('if {[catch {\nimport_device eagle_s20.db -package EG4S20BG256\n'
                      'open_project SD_to_Video.prj -noanalyze\nimport_db SD_to_Video_gate.db\n'
                      'write_verilog logo_mapped.v\n} err]} {puts stderr $err;exit 1}\nexit\n')
    mapped = build / 'logo_mapped.v'
    if mapped.exists():
        mapped.unlink()
    with (build / 'logo_mapped_console.log').open('wb') as stream:
        result = subprocess.run([args.td, script.name], cwd=build, stdout=stream, stderr=subprocess.STDOUT, timeout=180)
    if result.returncode or not mapped.exists():
        raise RuntimeError('Logo综合网表导出失败')
    blocks = [block for block in re.findall(r'  EG_PHY_BRAM #\(.*?\);', mapped.read_text(), re.S)
              if 'logo_index_stage' in block]
    assert len(blocks) == 1, f'Logo应只使用一片BRAM9K，实际{len(blocks)}片'
    block = blocks[0]
    assert '.DATA_WIDTH_A("4")' in block and '.MODE("SP8K")' in block
    words = {int(index, 16): int(value, 16) for index, value in
             re.findall(r"\.INIT_([0-9A-F]+)\(256'h([0-9A-F]+)\)", block, re.I)}
    assert len(words) == 32
    packed = sum(words[i] << (256 * i) for i in range(32))
    source = (root / 'src/video_presentation.v').read_text(encoding='utf-8')
    rows = {int(row): data for row, data in re.findall(r"(\d+):logo_row=224'h([0-9a-f]+)", source)}
    assert len(rows) == 36
    expected = [int(index, 16) for y in range(36) for index in rows[y]] + [0] * 32
    assert len(expected) == 2048
    for address, value in enumerate(expected):
        actual = (packed >> (4 * address)) & 15
        assert actual == value, (address, actual, value)
    print('PASS mapped Logo ROM: one BRAM9K (2048x4), all 2048 initialization words exact, including transparency and padding')


if __name__ == '__main__':
    main()
