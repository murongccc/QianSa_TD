"""实测坐标映射、帧快照 CDC、十字和严格视频对照；不生成 bitstream。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=['mapper', 'snapshot', 'stream', 'marker', 'video'])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = root / 'prj/log/touch_marker_regression_20261009'
    output.mkdir(parents=True, exist_ok=True)
    tools = {name: shutil.which(name) for name in ['vlib', 'vlog', 'vsim', 'git']}
    if not all(tools.values()):
        raise SystemExit('ModelSim and Git must be on PATH')
    library = output / 'work'

    def run(label, command, passed=False):
        with (output / (label + '.log')).open('wb') as stream:
            result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=600)
        text = (output / (label + '.log')).read_text(errors='replace')
        if result.returncode or 'FAIL' in text or (passed and 'PASS' not in text):
            print('\n'.join(text.splitlines()[-20:]))
            raise SystemExit(f'FAIL {label}; see {output}')
        print('\n'.join(line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line or 'Warnings:' in line), flush=True)

    baseline = subprocess.check_output([tools['git'], 'show', 'd2cea4d:src/video_presentation.v'], cwd=root).decode('utf-8')
    baseline = re.sub(r'\bvideo_presentation\b', 'baseline_video_presentation', baseline)
    baseline_path = output / 'baseline_video_presentation.v'
    baseline_path.write_text(baseline, encoding='utf-8')
    if not library.exists():
        run('library', [tools['vlib'], str(library)])
    cases = [args.case] if args.case else ['mapper', 'snapshot', 'stream', 'marker', 'video']
    tops = {'mapper': 'tb_touch_pixel_mapper', 'snapshot': 'tb_touch_frame_snapshot',
            'marker': 'tb_touch_marker', 'video': 'tb_touch_video_overlay', 'stream': 'tb_touch_stream_snapshot'}
    sources = ['src/test/eg_logic_mult_model.v', 'src/touch_pixel_mapper.v', 'src/touch_frame_snapshot.v',
               'src/touch_marker.v', 'src/ring_spectrum_renderer.v', 'src/video_presentation.v', str(baseline_path)]
    run('compile', [tools['vlog'], '-work', str(library), *sources,
                    *['src/test/' + tops[case] + '.v' for case in cases],
                    'src/test/tb_video_presentation.v', 'src/test/tb_video_presentation_startup.v'])
    for case in cases:
        run(case, [tools['vsim'], '-c', '-lib', str(library), tops[case],
                   '-do', 'src/test/run_touch_uart_debug.do'], True)
    if 'video' in cases:
        for top in ['tb_video_presentation', 'tb_video_presentation_startup']:
            run(top, [tools['vsim'], '-c', '-lib', str(library), top,
                      '-do', 'src/test/run_touch_uart_debug.do'], True)
    print(f'PASS touch marker regression; logs: {output}')


if __name__ == '__main__':
    main()
