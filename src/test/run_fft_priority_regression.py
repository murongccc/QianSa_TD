"""保留 Hann/keep 的 FFT 优化：实际修改前快照和逐拍对照。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-dir',type=Path)
    parser.add_argument('--baseline-ref',default='df39cf4a39197240697b87ee3067f7c4cf651531')
    parser.add_argument('--output',type=Path,default=Path('prj/log/fft_priority_regression_20261011'))
    parser.add_argument('--case',choices=['quick','fft','pixels','all'],default='all')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    output=(root/args.output).resolve();output.mkdir(parents=True,exist_ok=True)
    tools={name:shutil.which(name) for name in ['vlib','vlog','vsim','git']}
    if not all(tools.values()):raise RuntimeError('ModelSim and Git must be on PATH')
    baseline=[]
    for name in ['audio_fft_spectrum','ring_spectrum_renderer','video_presentation']:
        if args.baseline_dir:
            text=(root/args.baseline_dir/(name+'.v')).read_text(encoding='utf-8')
        else:
            text=subprocess.check_output([tools['git'],'show',f'{args.baseline_ref}:src/{name}.v'],cwd=root).decode('utf-8')
        text=re.sub(r'\b(audio_fft_spectrum|legacy_audio_fft_spectrum|reference_fft_spectrum|fft_spectrum_bank_ram|ring_spectrum_renderer|video_presentation)\b',lambda m:'baseline_'+m[0],text)
        path=output/('baseline_'+name+'.v');path.write_text(text,encoding='utf-8');baseline.append(path)
    def run(name,command,expect=False):
        with (output/(name+'.log')).open('wb') as log:
            result=subprocess.run(command,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=1200)
        text=(output/(name+'.log')).read_text(errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]',text) or (expect and 'PASS' not in text):
            print('\n'.join(text.splitlines()[-12:]),flush=True)
            raise RuntimeError(f'{name} failed; see {output}')
        print('PASS '+name,flush=True)
    run('reference_tables',[sys.executable,'src/test/generate_reference_fft_tables.py','--check'],True)
    run('ring_tables',[sys.executable,'src/test/generate_ring_visual_tables.py','--check'],True)
    lib=(output/'work').as_posix()
    if not Path(lib).exists():run('library',[tools['vlib'],lib])
    sources=['E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','src/test/eg_logic_mult_model.v','src/rhythm_block_ram.v',
        'src/audio_fft_spectrum.v','src/ring_spectrum_renderer.v','src/video_presentation.v',*map(str,baseline),
        *['src/test/'+n+'.v' for n in ['tb_fft_priority_arithmetic','tb_fft_display_equivalence','tb_fft_display_pixels',
            'tb_fft_display_cache','tb_reference_dynamics','tb_reference_ring','tb_reference_fft_spectrum','tb_fft_bank_32k','tb_audio_fft_spectrum']]]
    run('compile',[tools['vlog'],'-work',lib,*sources])
    def sim(name,top,parameters=()):run(name,[tools['vsim'],'-c','-lib',lib,top,*parameters,'-do','src/test/run_pcm_audio_player.do'],True)
    if args.case in ['quick','all']:
        for top in ['tb_fft_priority_arithmetic','tb_fft_display_cache','tb_reference_dynamics','tb_reference_ring','tb_fft_bank_32k']:
            sim(top,top)
        sim('legacy_fft','tb_audio_fft_spectrum')
    if args.case in ['fft','all']:
        for points in [512,1024,2048]:sim('fft_'+str(points),'tb_fft_display_equivalence',['-gFFT_POINTS='+str(points)])
    if args.case in ['pixels','all']:sim('pixels_21_frames','tb_fft_display_pixels')


if __name__=='__main__':main()
