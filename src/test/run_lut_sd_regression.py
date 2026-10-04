"""LUT/SD 候选的严格显示对照和返回流水边界回归。"""
import argparse
import re
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('prj/log/lut_sd_equivalence'))
    parser.add_argument('--skip-display', action='store_true', help='复用已通过且未变更的显示对照')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = (root / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    library = str(output / 'work')

    def run(name, tool, arguments, expect=False):
        with (output / (name+'.log')).open('wb') as log:
            result = subprocess.run([shutil.which(tool), *arguments], cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=600)
        text = (output / (name+'.log')).read_text(errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]', text) or (expect and 'PASS' not in text):
            raise RuntimeError(f'{name} failed: {output / (name+".log")}')
        print('PASS '+name, flush=True)

    run('library','vlib',[library])
    run('compile','vlog',['-work',library,'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v',
        'src/test/eg_logic_mult_model.v','src/rhythm_block_ram.v','src/rhythm_hud.v',
        'src/ring_spectrum_renderer.v','src/sd_sector_arbiter.v',
        'src/SD/bmp_read.v','src/test/tb_bmp_read_fat_chain.v',
        'src/test/tb_sd_registered_response.v','src/test/tb_lut_display_equivalence.v'])
    for mode in range(2):
        run('sd_mode_'+str(mode),'vsim',['-c','-lib',library,'tb_sd_registered_response',
            '-gREGISTER_RESPONSE='+str(mode),'-do','src/test/run_pcm_audio_player.do'],True)
    run('bmp_last_fat_byte','vsim',['-c','-lib',library,'tb_bmp_read_fat_chain',
        '-gFAT_EDGE=1','-do','src/test/run_pcm_audio_player.do'],True)
    if not args.skip_display:
        run('display_equivalence','vsim',['-c','-lib',library,'tb_lut_display_equivalence',
            '-do','src/test/run_pcm_audio_player.do'],True)


if __name__=='__main__':
    main()
