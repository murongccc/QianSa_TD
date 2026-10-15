"""数据通路控制优化：当前基线逐拍对照、独立像素模型及全状态取消重启。"""
from pathlib import Path
import argparse
import re
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[2]
OUTPUT=ROOT/'prj/log/datapath_controls_regression_20261015'
BASELINE='5080535521c161f3f25708bd6409315f53a2fb4b'

def run(label,command,require_pass=False):
    path=OUTPUT/(label+'.log')
    with path.open('wb') as log:
        result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
    text=path.read_text(errors='replace')
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|FAIL',text) or (require_pass and 'PASS' not in text):
        print('\n'.join(text.splitlines()[-20:]),flush=True)
        raise SystemExit(f'FAIL {label}; see {path}')
    print(label+': '+ ' / '.join([line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line][-2:]),flush=True)

def main():
    global OUTPUT
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',default='prj/log/datapath_controls_regression_20261015')
    parser.add_argument('--case',choices=['boundaries','full_output','small_output','single_column','single_row','single_output','reset_sweep','dsp_full_smoke','official_quick'])
    args=parser.parse_args()
    OUTPUT=ROOT/args.output
    OUTPUT.mkdir(parents=True,exist_ok=True)
    commands={name:shutil.which(name) for name in ['git','vlib','vlog','vsim']}
    if not all(commands.values()):raise SystemExit('Git and ModelSim must be on PATH')
    text=subprocess.check_output([commands['git'],'show',f'{BASELINE}:src/SD/bmp_bilinear_scaler.v'],cwd=ROOT).decode('utf-8')
    reference=OUTPUT/'baseline_scaler.v'
    reference.write_text(re.sub(r'\bbmp_bilinear_scaler\b','baseline_bmp_bilinear_scaler',text),encoding='utf-8')
    library=OUTPUT/'work'
    if not library.exists():run('library',[commands['vlib'],str(library)])
    run('compile',[commands['vlog'],'-work',str(library),'E:/AnLuTD/sim_release/eg4/eg_logic_mult.v',
        'src/test/tb_bmp_bilinear_scaler.v','src/SD/bmp_bilinear_scaler.v',str(reference),
        'src/test/tb_scaler_datapath_controls.v'])
    cases=[('boundaries',19,14,1),('full_output',640,480,1),('small_output',7,5,0),
           ('single_column',1,5,0),('single_row',7,1,0),('single_output',1,1,0),('reset_sweep',19,14,0),('dsp_full_smoke',640,480,1)]
    for name,w,h,boundaries in cases:
        if args.case=='official_quick':
            if name in ['full_output','dsp_full_smoke']:continue
        elif args.case and name!=args.case:continue
        run(name,[commands['vsim'],'-c','-lib',str(library),'tb_scaler_datapath_controls',
            f'-gOUT_W={w}',f'-gOUT_H={h}',f'-gRUN_BOUNDARIES={boundaries}',f'-gRESET_SWEEP={int(name=="reset_sweep")}',f'-gFULL_SMOKE={int(name=="dsp_full_smoke")}',
            '-do','src/test/run_pcm_audio_player.do'],True)
    print('PASS datapath controls: '+(args.case or '8 configurations')+'; logs: '+str(OUTPUT),flush=True)

if __name__=='__main__':main()
