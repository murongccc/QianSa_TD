"""第四阶段 RTL 回归；日志写入独立目录，不生成 bitstream。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('prj/log/rhythm_stage4_regression'))
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
    tests = ['tb_rhythm_debounce_bank', 'tb_rhythm_session', 'tb_rhythm_renderer', 'tb_rhythm_note_style', 'tb_rhythm_renderer_session_reset', 'tb_rhythm_background_mode',
             'tb_rhythm_playback', 'tb_rhythm_media_freeze', 'tb_rhythm_image_guard']
    sources = ['rhythm_block_ram', 'rhythm_judge_core', 'rhythm_auto_input', 'rhythm_game_engine',
               'rhythm_session_controller', 'rhythm_font', 'rhythm_hud', 'rhythm_game_renderer',
               'pcm_audio_player', 'ring_spectrum_renderer', 'video_presentation',
               'image_controls', 'media_session_controller', 'fat32_chart_reader',
               'rhythm_chart_buffer', 'fat32_wav_reader', 'sd_sector_arbiter',
               'rhythm_sd_resources', 'domain_reset_sync', 'fat32_bmp_catalog', 'sd_media_pipeline']
    run('compile', [binaries['vlog'], '-work', library, '+incdir+src/SD',
                    'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v', 'src/test/eg_logic_mult_model.v',
                    'src/SD/color_bar.v', *[f'src/{name}.v' for name in sources], *[f'src/test/{name}.v' for name in tests]])
    for test in tests:
        run(test, [binaries['vsim'], '-c', '-lib', library, test,
                   '-do', 'src/test/run_pcm_audio_player.do'], True)
    run('note_style_distributed_geometry', [binaries['vsim'], '-c', '-lib', library, 'tb_rhythm_note_style',
                                           '-gBLOCK_GEOMETRY=0', '-do', 'src/test/run_pcm_audio_player.do'], True)


if __name__ == '__main__':
    main()
