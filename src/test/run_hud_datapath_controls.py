"""HUD 数据工作寄存器去复位/保持使能：逐拍输出与字符写入对照。"""
from pathlib import Path
import argparse,re,shutil,subprocess
ROOT=Path(__file__).resolve().parents[2]
OUTPUT=ROOT/'prj/log/datapath_controls_hud_regression_20261015'
BASELINE='5080535521c161f3f25708bd6409315f53a2fb4b'

def run(label,args,simulate=False):
    path=OUTPUT/(label+'.log')
    with path.open('wb') as log:
        result=subprocess.run(args,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=300)
    text=path.read_text(errors='replace')
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|FAIL',text) or (simulate and 'PASS' not in text):
        print('\n'.join(text.splitlines()[-16:]),flush=True)
        raise SystemExit('FAIL '+label)
    print(label+': '+' / '.join([s for s in text.splitlines() if 'PASS' in s or 'Errors:' in s][-2:]),flush=True)

def main():
    global OUTPUT
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',default='prj/log/datapath_controls_hud_regression_20261015')
    args=parser.parse_args()
    OUTPUT=ROOT/args.output
    OUTPUT.mkdir(parents=True,exist_ok=True)
    commands={n:shutil.which(n) for n in ['git','vlib','vlog','vsim']}
    if not all(commands.values()):raise SystemExit('ModelSim/Git unavailable')
    old=subprocess.check_output([commands['git'],'show',BASELINE+':src/rhythm_hud.v'],cwd=ROOT).decode('utf-8')
    reference=OUTPUT/'baseline_hud.v'
    reference.write_text(re.sub(r'\brhythm_hud\b','baseline_rhythm_hud',old),encoding='utf-8')
    lib=OUTPUT/'work'
    if not lib.exists():run('library',[commands['vlib'],str(lib)])
    run('compile',[commands['vlog'],'-work',str(lib),'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v',
        'src/rhythm_block_ram.v','src/rhythm_hud.v',str(reference),'src/test/tb_hud_datapath_controls.v'])
    for block in [0,1]:
        for stream in [0,1]:
            for text in [0,1]:
                run(f'hud_{block}{stream}{text}',[commands['vsim'],'-c','-lib',str(lib),'tb_hud_datapath_controls',
                    f'-gBLOCK={block}',f'-gSTREAM={stream}',f'-gTEXT={text}','-do','src/test/run_pcm_audio_player.do'],True)
    print('PASS HUD datapath: all 8 configurations',flush=True)

if __name__=='__main__':main()
