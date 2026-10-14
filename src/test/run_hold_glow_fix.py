"""Hold显示长度与光晕背景合成修复验证，不运行实现流程。"""
from pathlib import Path
import re,shutil,subprocess
root=Path(__file__).resolve().parents[2];out=root/'prj/log/hold_glow_fix_20261012';out.mkdir(parents=True,exist_ok=True)
def run(name,command,passed=False):
    with (out/(name+'.log')).open('wb') as f:
        r=subprocess.run(command,cwd=root,stdout=f,stderr=subprocess.STDOUT,timeout=300)
    s=(out/(name+'.log')).read_text(errors='replace')
    if r.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]',s) or (passed and 'PASS' not in s):
        raise RuntimeError(name+' failed\n'+'\n'.join(s.splitlines()[-14:]))
    print('\n'.join(l for l in s.splitlines() if 'PASS' in l or 'Errors:' in l),flush=True)
lib=str(out/'work')
if not Path(lib).exists():run('library',[shutil.which('vlib'),lib])
names=['rhythm_game_renderer','rhythm_block_ram','rhythm_font','rhythm_hud','image_info_metadata','image_info_osd','image_osd_font','video_presentation','ring_spectrum_renderer']
cases=['tb_video_glow_blend','tb_hold_glow_fix']
run('compile',[shutil.which('vlog'),'-work',lib,'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','src/test/eg_logic_mult_model.v',
    *[str(root/'src'/(n+'.v')) for n in names],*[str(root/'src/test'/(n+'.v')) for n in cases]])
for case in cases:run(case,[shutil.which('vsim'),'-c','-lib',lib,case,'-do','src/test/run_pcm_audio_player.do'],True)
