"""Logo和暂停符号的真实视频链回归，保存最终RGB预览；不生成位流。"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
from PIL import Image

root = Path(__file__).resolve().parents[2]
out = root / 'prj/log/video_logo_20261017'
out.mkdir(parents=True, exist_ok=True)


def run(name, command, passed=False):
    with (out / (name + '.log')).open('wb') as stream:
        result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=600)
    text = (out / (name + '.log')).read_text(errors='replace')
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|\bFAIL\b', text) or passed and 'PASS' not in text:
        raise RuntimeError(name + '\n' + '\n'.join(text.splitlines()[-18:]))
    print(name + ': ' + '; '.join(line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line), flush=True)


run('generate', [sys.executable, 'src/test/generate_video_logo.py'], True)
library = str(out / 'work')
if not Path(library).exists():
    run('library', [shutil.which('vlib'), library])
modules = ['video_presentation', 'ring_spectrum_renderer', 'image_info_osd', 'image_osd_font',
           'rhythm_game_renderer', 'rhythm_block_ram', 'rhythm_hud', 'rhythm_font']
run('compile', [shutil.which('vlog'), '-work', library, 'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v',
                'src/test/eg_logic_mult_model.v', *[f'src/{name}.v' for name in modules], 'src/test/tb_video_logo.v'])
run('video_logo', [shutil.which('vsim'), '-c', '-lib', library, 'tb_video_logo',
                   '-do', 'src/test/run_startup_regression.do'], True)
for name in ['startup', 'image', 'game', 'adjusted']:
    with Image.open(out / (name + '.ppm')) as image:
        image.save(out / (name + '.png'))
print('PASS final RGB previews: ' + str(out))
