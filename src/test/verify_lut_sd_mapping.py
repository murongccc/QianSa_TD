"""核对已导出的综合网表中 HUD 的全部 INIT 和环形几何 DSP 映射。"""
import argparse
import re
from pathlib import Path
from generate_rhythm_hud_text import words


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    text = (args.build/'mapped_check.v').read_text()
    blocks = re.findall(r'  EG_PHY_BRAM[^;]*;', text)
    hud = [block for block in blocks if 'static_text$text_data' in block]
    assert len(hud) == 1, f'expected one HUD static ROM, got {len(hud)}'
    block = hud[0]
    assert '.DATA_WIDTH_A("9")' in block and '.MODE("SP8K")' in block
    init = {key: int(value,16) for key,value in re.findall(r"\.(INIT_[0-9A-F]+)\(256'h([0-9A-F]+)\)",block)}
    packed = sum(init[f'INIT_{i:02X}'] << (256*i) for i in range(32))
    for address,expected in enumerate(words()):
        actual = (packed >> (8*address)) & 255
        assert actual == expected, f'ROM address {address}: {actual} != {expected}'
    print('PASS mapped HUD text: one BRAM9K, all 1024 INIT words exact')
    dsps = re.findall(r'  EG_PHY_MULT18[^;]*;',text)
    ring = [block for block in dsps if '/dsp_bounds$' in block or '/dsp_axis$' in block]
    assert len(ring)==6 and all('.MODE("MULT9X9C")' in block for block in ring)
    print('PASS ring geometry: 11 logical 9x9 products packed into six physical DSP')
    timing=(args.build/'SD_to_Video_gate.timing').read_text()
    section=timing.split('Path Group     :     sd_card_clk -> sd_card_clk',1)[1]
    selected=[line for line in section.splitlines() if re.match(r'^(Slack|Begin Point|End Point|Data Path Delay|Logic Level) ',line)]
    print('\n'.join(selected[:5]))


if __name__=='__main__':
    main()
