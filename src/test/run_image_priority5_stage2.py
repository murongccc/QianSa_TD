"""第二批缩放优化：第一批提交逐拍对照及独立双线性算术模型。"""
from pathlib import Path
import argparse
import re
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[2]
OUTPUT=ROOT/'prj/log/image_stage2_regression_20261012'
BASELINE='a6679f564ea78a03029bdc208a029d991ababc83'

def run(label,command,require_pass=False):
    path=OUTPUT/(label+'.log')
    with path.open('wb') as log:
        result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=900)
    text=path.read_text(errors='replace')
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|FAIL',text) or (require_pass and 'PASS' not in text):
        print('\n'.join(text.splitlines()[-20:]),flush=True)
        raise SystemExit(f'FAIL {label}; see {path}')
    print(label+': '+ ' / '.join([line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line][-2:]),flush=True)

def main():
    global OUTPUT
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',default='prj/log/image_stage2_regression_20261012')
    parser.add_argument('--case',choices=['boundaries','full_output','small_output','single_column','single_row','single_output'])
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
    run('compile',[commands['vlog'],'-work',str(library),'src/test/eg_logic_mult_model.v',
        'src/test/tb_bmp_bilinear_scaler.v','src/SD/bmp_bilinear_scaler.v',str(reference),
        'src/test/tb_image_scaler_stage2_equivalence.v'])
    cases=[('boundaries',19,14,1),('full_output',640,480,1),('small_output',7,5,0),
           ('single_column',1,5,0),('single_row',7,1,0),('single_output',1,1,0)]
    for name,w,h,boundaries in cases:
        if args.case and name!=args.case:continue
        run(name,[commands['vsim'],'-c','-lib',str(library),'tb_image_scaler_stage2_equivalence',
            f'-gOUT_W={w}',f'-gOUT_H={h}',f'-gRUN_BOUNDARIES={boundaries}',
            '-do','src/test/run_pcm_audio_player.do'],True)
    print('PASS image stage2: '+(args.case or '6 configurations')+'; logs: '+str(OUTPUT),flush=True)

if __name__=='__main__':main()
