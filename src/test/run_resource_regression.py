"""资源优化回归：保留真实 FIFO 模型、优化前 FFT 对照及可选完整 WAV 重放。"""
import argparse
import csv
from pathlib import Path
import re
import shutil
import subprocess
import sys

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=Path('prj/log/resource_final_regression'))
    parser.add_argument('--baseline-ref',default='2c57bbe')
    parser.add_argument('--td-root',type=Path,default=Path('E:/AnLuTD'))
    parser.add_argument('--wav-samples',type=Path)
    parser.add_argument('--skip-video',action='store_true',help='继续已通过的视频回归，复用其仿真库')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    output=(root/args.output).resolve()
    output.mkdir(parents=True,exist_ok=True)
    binaries={name:shutil.which(name) for name in ['vlib','vlog','vsim','git']}
    if not all(binaries.values()):raise RuntimeError('vlib/vlog/vsim/git must be on PATH')
    def check(name,result):
        text=(output/f'{name}.log').read_text(errors='replace')
        if result or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]',text):
            raise RuntimeError(f'{name} failed: {output/name}.log')
        return text
    def run(name,command,expect_pass=False):
        with (output/f'{name}.log').open('wb') as log:
            result=subprocess.run(command,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=900)
        text=check(name,result.returncode)
        if expect_pass and 'PASS' not in text:raise RuntimeError(f'{name} assertions did not finish')
        print(f'PASS {name}',flush=True)
    baseline=subprocess.check_output([binaries['git'],'show',f'{args.baseline_ref}:src/audio_fft_spectrum.v'],cwd=root).decode('utf-8')
    baseline=re.sub(r'\b(audio_fft_spectrum|legacy_audio_fft_spectrum|reference_fft_spectrum|fft_spectrum_bank_ram)\b',lambda m:'baseline_'+m[0],baseline)
    (output/'baseline_fft.v').write_text(baseline,encoding='utf-8')
    def compile_group(name,sources,options=()):
        library=(output/name/'work').as_posix()
        (output/name).mkdir(exist_ok=True)
        if not Path(library).exists():run(name+'_library',[binaries['vlib'],library])
        run(name+'_compile',[binaries['vlog'],'-work',library,*options,*map(str,sources)])
        return library
    def simulate(name,library,top,parameters=()):
        run(name,[binaries['vsim'],'-c','-lib',library,top,*parameters,'-do','src/test/run_pcm_audio_player.do'],True)
    run('reference_tables',[sys.executable,'src/test/generate_reference_fft_tables.py','--check'],True)
    video=compile_group('video',[
        'src/audio_fft_spectrum.v','src/ring_spectrum_renderer.v','src/video_presentation.v',
        'src/image_controls.v','src/media_session_controller.v',output/'baseline_fft.v',
        *[f'src/test/{name}.v' for name in ['tb_fft_resource_equivalence','tb_reference_fft_spectrum',
          'tb_reference_dynamics','tb_reference_ring','tb_video_presentation',
          'tb_video_presentation_startup','tb_image_controls','tb_reference_wav']]])
    if not args.skip_video:
        for top in ['tb_fft_resource_equivalence','tb_reference_dynamics','tb_reference_ring',
                'tb_image_controls','tb_video_presentation_startup']:
            simulate(top,video,top)
        simulate('video_compat',video,'tb_video_presentation')
        simulate('video_reference',video,'tb_video_presentation',['-gREFERENCE_SPECTRUM=1'])
        simulate('reference2048',video,'tb_reference_fft_spectrum',['-gFFT_POINTS=2048'])
    media_tests=['tb_fat32_wav_reader','tb_fat32_wav_reader_direct_volume','tb_wav_reader_resource_opt',
                 'tb_wav_streaming_headers','tb_sd_media_audio_start','tb_fat32_bmp_catalog',
                 'tb_fat32_bmp_catalog_five','tb_bmp_catalog_fat_capture','tb_bmp_read_resource_opt',
                 'tb_bmp_read_v5_header','tb_bmp_read_fat_chain','tb_media_session_controller']
    media=compile_group('media',['src/fat32_wav_reader.v','src/fat32_bmp_catalog.v',
        'src/SD/bmp_read.v','src/media_session_controller.v',*[f'src/test/{name}.v' for name in media_tests]])
    for top in media_tests:simulate(top,media,top)
    simulate('wav_shared_volume',media,'tb_fat32_wav_reader',['-gUSE_SHARED_VOLUME=1'])
    scaler=compile_group('scaler',['src/SD/bmp_bilinear_scaler.v','src/test/eg_logic_mult_model.v',
        'src/test/tb_bmp_bilinear_scaler.v','src/test/tb_bmp_scaler_resource_opt.v'])
    simulate('scaler_boundaries',scaler,'tb_bmp_scaler_resource_opt')
    simulate('scaler_640',scaler,'tb_bmp_scaler_resource_opt',['-gOUT_W=640','-gOUT_H=480','-gRUN_BOUNDARIES=0'])
    integration=compile_group('integration',[
        args.td_root/'sim_release/eg4/eg_logic_bram.v',
        args.td_root/'sim_release/eg4/eg_logic_ramfifo.v',
        'prj/al_ip/source_pixel_fifo_ip/RTL/soft_fifo_f9a960ae4922.v',
        'prj/al_ip/source_pixel_fifo_ip/source_pixel_fifo_ip.v',
        'src/test/eg_logic_mult_model.v','src/SD/bmp_bilinear_scaler.v','src/SD/bmp_read.v',
        'src/domain_reset_sync.v','src/fat32_bmp_catalog.v','src/fat32_wav_reader.v',
        'src/sd_sector_arbiter.v','src/media_session_controller.v','src/sd_media_pipeline.v',
        'src/test/tb_sd_media_scaler_commit.v'],['+define+MEDIA_STARTUP_MODEL'])
    simulate('media_scaler_commit',integration,'tb_sd_media_scaler_commit')
    if args.wav_samples:
        sample_path=args.wav_samples.resolve()
        count=sum(1 for line in sample_path.open() if line.strip())
        old_tb=(root/'src/test/tb_reference_wav.v').read_text(encoding='utf-8')
        old_tb=old_tb.replace('module tb_reference_wav;','module tb_baseline_reference_wav;').replace('audio_fft_spectrum #','baseline_audio_fft_spectrum #')
        (output/'tb_baseline_reference_wav.v').write_text(old_tb,encoding='utf-8')
        run('wav_baseline_compile',[binaries['vlog'],'-work',video,str(output/'tb_baseline_reference_wav.v')])
        # 两次独立重放只读同一输入，日志和输出分开，允许并行执行。
        processes=[]
        for label,top in [('wav_baseline','tb_baseline_reference_wav'),('wav_candidate','tb_reference_wav')]:
            log=(output/f'{label}.log').open('wb')
            command=[binaries['vsim'],'-c','-lib',video,top,f'+SAMPLES={sample_path.as_posix()}',
                     f'+COUNT={count}',f'+OUTPUT={(output/(label+".csv")).as_posix()}',
                     '-do','src/test/run_pcm_audio_player.do']
            processes.append((label,subprocess.Popen(command,cwd=root,stdout=log,stderr=subprocess.STDOUT),log))
        for label,process,log in processes:
            result=process.wait(timeout=900);log.close()
            if 'PASS' not in check(label,result):raise RuntimeError(f'{label} did not finish')
            print(f'PASS {label}',flush=True)
        baseline_rows=list(csv.reader((output/'wav_baseline.csv').open()))
        candidate_rows=list(csv.reader((output/'wav_candidate.csv').open()))
        if baseline_rows!=candidate_rows:raise RuntimeError('WAV frame values or publication timing changed')
        print(f'PASS WAV equivalence: {count} samples, {len(candidate_rows)-1} frames',flush=True)
    print('PASS resource regression',flush=True)

if __name__=='__main__':main()
