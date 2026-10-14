"""FFT 显示缓存：修改前独立 RTL、真实 BRAM 和逐像素严格对照。"""
import argparse
import re
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', default='5e4a2f7')
    parser.add_argument('--output', type=Path, default=Path('prj/log/fft_display_regression'))
    parser.add_argument('--only', choices=('cache', 'fft', 'pixels'), help='仅重跑发生变化的测试组')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = (root / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    library = (output / 'work').as_posix()

    def run(name, tool, arguments, expect=False):
        with (output / (name + '.log')).open('wb') as log:
            result = subprocess.run([shutil.which(tool), *arguments], cwd=root,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=900)
        text = (output / (name + '.log')).read_text(errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]', text) or (expect and 'PASS' not in text):
            raise RuntimeError(f'{name} failed: {output / (name + ".log")}')
        print('PASS ' + name, flush=True)

    old = subprocess.check_output(['git', 'show', f'{args.baseline_ref}:src/audio_fft_spectrum.v'], cwd=root).decode('utf-8')
    old = re.sub(r'\b(audio_fft_spectrum|legacy_audio_fft_spectrum|reference_fft_spectrum|fft_spectrum_bank_ram)\b',
                 lambda m: 'baseline_' + m[0], old)
    baseline = output / 'baseline_fft.v'
    baseline.write_text(old, encoding='utf-8')
    baseline_display = []
    for name in ('ring_spectrum_renderer', 'video_presentation'):
        old = subprocess.check_output(['git', 'show', f'{args.baseline_ref}:src/{name}.v'], cwd=root).decode('utf-8')
        old = re.sub(r'\b(ring_spectrum_renderer|video_presentation)\b', lambda m: 'baseline_' + m[0], old)
        path = output / ('baseline_' + name + '.v')
        path.write_text(old, encoding='utf-8')
        baseline_display.append(path.as_posix())
    if not Path(library).exists():
        run('library', 'vlib', [library])
    run('compile', 'vlog', ['-work', library, 'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v',
        'src/test/eg_logic_mult_model.v', 'src/rhythm_block_ram.v', 'src/audio_fft_spectrum.v',
        baseline.as_posix(), 'src/ring_spectrum_renderer.v', 'src/image_info_metadata.v','src/image_info_osd.v','src/image_osd_font.v','src/video_presentation.v', *baseline_display,
        'src/test/tb_fft_display_cache.v', 'src/test/tb_fft_display_equivalence.v', 'src/test/tb_fft_display_pixels.v'])
    if args.only in (None, 'cache'):
        run('cache_boundaries', 'vsim', ['-c', '-lib', library, 'tb_fft_display_cache',
            '-do', 'src/test/run_pcm_audio_player.do'], True)
    if args.only in (None, 'fft'):
        for points in (512, 1024, 2048):
            run('fft_' + str(points), 'vsim', ['-c', '-lib', library, 'tb_fft_display_equivalence',
                '-gFFT_POINTS=' + str(points), '-do', 'src/test/run_pcm_audio_player.do'], True)
    if args.only in (None, 'pixels'):
        run('pixels_21_frames', 'vsim', ['-c', '-lib', library, 'tb_fft_display_pixels',
            '-do', 'src/test/run_pcm_audio_player.do'], True)


if __name__ == '__main__':
    main()
