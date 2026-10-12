"""四轨反馈的实际渲染与像素校验；测试不进入板级源集。"""
from pathlib import Path
import re, shutil, subprocess
root=Path(__file__).resolve().parents[2]
out=root/'prj/log/touch_glow_20261012';out.mkdir(parents=True,exist_ok=True)
def run(name,command,passed=False):
    with (out/(name+'.log')).open('wb') as f:
        result=subprocess.run(command,cwd=root,stdout=f,stderr=subprocess.STDOUT,timeout=300)
    text=(out/(name+'.log')).read_text(errors='replace')
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]',text) or (passed and 'PASS' not in text):
        raise RuntimeError(name+' failed\n'+'\n'.join(text.splitlines()[-12:]))
    print('\n'.join(l for l in text.splitlines() if 'PASS' in l or 'Errors:' in l),flush=True)
lib=str(out/'work')
if not Path(lib).exists():run('library',[shutil.which('vlib'),lib])
names=['rhythm_game_renderer','rhythm_block_ram','rhythm_font','rhythm_hud']
run('compile',[shutil.which('vlog'),'-work',lib,'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','src/test/eg_logic_mult_model.v',
    *[str(root/'src'/(name+'.v')) for name in names],'src/test/tb_touch_lane_glow.v'])
run('glow',[shutil.which('vsim'),'-c','-lib',lib,'tb_touch_lane_glow','-do','src/test/run_pcm_audio_player.do'],True)
