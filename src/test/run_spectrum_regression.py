"""运行频谱、环形绘制和视频呈现的 ModelSim 局部回归。"""
import argparse
import re
import shutil
import sys
import subprocess
from pathlib import Path


def main():
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=repo / "prj/log/spectrum_regression")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    library = (output / "work").as_posix()
    binaries = {}
    for name in ("vlib", "vlog", "vsim"):
        binaries[name] = shutil.which(name)
        if not binaries[name]:
            raise RuntimeError(f"ModelSim {name} is not on PATH")

    def run(name, command, expect_pass=False):
        result = subprocess.run(command, cwd=repo, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=600 if name=="reference2048" else 180)
        text = result.stdout.decode("utf-8", errors="replace")
        (output / f"{name}.log").write_text(text, encoding="utf-8")
        # 部分 OEM 版本在 $fatal 后仍返回零，必须同时检查日志。
        if result.returncode or re.search(r"\*\* (?:Fatal|Error):|Errors: [1-9]", text):
            raise RuntimeError(f"{name} failed; see {output / (name + '.log')}")
        if expect_pass and "PASS" not in text:
            raise RuntimeError(f"{name} did not complete its assertions")
        print(f"PASS {name}")

    run("tables", [sys.executable, "src/test/generate_ring_visual_tables.py", "--check"], True)
    run("reference_tables", [sys.executable, "src/test/generate_reference_fft_tables.py", "--check"], True)
    if not (output / "work").exists():
        run("library", [binaries["vlib"], library])
    sources = ["src/test/eg_logic_mult_model.v", "E:/AnLuTD/sim_release/eg4/eg_logic_bram.v", "src/rhythm_block_ram.v", "src/audio_fft_spectrum.v", "src/ring_spectrum_renderer.v",
               "src/pcm_audio_player.v", "src/test/tb_pcm_audio_player.v",
               "src/video_presentation.v", "src/test/tb_audio_fft_spectrum.v",
               "src/test/tb_ring_spectrum_renderer.v", "src/test/tb_video_presentation.v",
               "src/test/tb_video_presentation_startup.v", "src/test/tb_reference_fft_spectrum.v",
               "src/test/tb_reference_ring.v", "src/test/tb_reference_dynamics.v"]
    run("compile", [binaries["vlog"], "-work", library, *sources])
    tests = [("pcm_player", "tb_pcm_audio_player", []),
             ("reference_dynamics", "tb_reference_dynamics", []),
             ("fft256", "tb_audio_fft_spectrum", ["-gFFT_POINTS=256"]),
             ("fft512", "tb_audio_fft_spectrum", ["-gFFT_POINTS=512"]),
             ("reference512", "tb_reference_fft_spectrum", ["-gFFT_POINTS=512"]),
             ("reference2048", "tb_reference_fft_spectrum", ["-gFFT_POINTS=2048"]),
             ("reference_ring", "tb_reference_ring", []),
             ("ring", "tb_ring_spectrum_renderer", []),
             ("video", "tb_video_presentation", []),
             ("reference_video", "tb_video_presentation", ["-gREFERENCE_SPECTRUM=1"]),
             ("startup", "tb_video_presentation_startup", [])]
    for name, module, parameters in tests:
        run(name, [binaries["vsim"], "-c", "-lib", library, module, *parameters,
                   "-do", "src/test/run_pcm_audio_player.do"], expect_pass=True)


if __name__ == "__main__":
    main()
