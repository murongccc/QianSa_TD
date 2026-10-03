"""第三阶段 RTL 回归；日志写入独立目录，不生成 bitstream。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('prj/log/rhythm_stage3_regression'))
    parser.add_argument('--real-chart', type=Path, default=Path('prj/log/rhythm_assets/brave_shine_normal/GAME.BIN'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = (root / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    binaries = {name: shutil.which(name) for name in ['vlib', 'vlog', 'vsim']}
    if not all(binaries.values()):
        raise RuntimeError('vlib/vlog/vsim must be on PATH')
    library = (output / 'work').as_posix()

    def run(name, command, expect_pass=False):
        with (output / (name + '.log')).open('wb') as log:
            result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        text = (output / (name + '.log')).read_text(errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]', text) or (expect_pass and 'PASS' not in text):
            raise RuntimeError(f'{name} failed; see {output / (name + ".log")}')
        print(f'PASS {name}', flush=True)

    if not (Path(library) / '_info').exists():
        run('library', [binaries['vlib'], library])
    tests = ['tb_rhythm_judge_core', 'tb_rhythm_max_score']
    if args.real_chart.exists():
        data = args.real_chart.read_bytes()
        if len(data) != 3368 or data[:4] != b'R4B1':
            raise RuntimeError('expected 413-note Dell Normal fixture')
        fixture = root / 'prj/log/rhythm_stage3_regression/notes.hex'
        fixture.parent.mkdir(parents=True, exist_ok=True)
        fixture.write_text(''.join(f'{int.from_bytes(data[i:i+8], "little"):016x}\n' for i in range(64, len(data), 8)))
        tests.append('tb_rhythm_song')
    else:
        print('SKIP real song: asset not present', flush=True)
    sources = ['rhythm_judge_core', 'rhythm_auto_input', 'rhythm_game_engine']
    run('compile', [binaries['vlog'], '-work', library,
                    *[f'src/{name}.v' for name in sources], *[f'src/test/{name}.v' for name in tests]])
    for test in tests:
        run(test, [binaries['vsim'], '-c', '-lib', library, test,
                   '-do', 'src/test/run_pcm_audio_player.do'], True)
    if 'tb_rhythm_song' in tests:
        run('song_test', [binaries['vsim'], '-c', '-lib', library, 'tb_rhythm_song',
                          '-gAUTO_MODE=0', '-do', 'src/test/run_pcm_audio_player.do'], True)


if __name__ == '__main__':
    main()
