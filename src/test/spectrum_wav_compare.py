"""准备 24-bit PCM WAV，汇总 ModelSim 新旧 RTL 的频谱/柱长对照。"""
import argparse
import csv
import json
import struct
from pathlib import Path

import numpy as np


def prepare(wav_path, output):
    data = Path(wav_path).read_bytes()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("Expected RIFF/WAVE")
    offset, fmt, pcm = 12, None, None
    while offset + 8 <= len(data):
        tag, size = struct.unpack_from("<4sI", data, offset)
        chunk = data[offset + 8:offset + 8 + size]
        if len(chunk) != size:
            raise ValueError("Truncated WAV chunk")
        if tag == b"fmt ":
            fmt = chunk
        elif tag == b"data":
            pcm = chunk
        offset += 8 + size + size % 2
    if fmt is None or pcm is None:
        raise ValueError("Missing fmt/data")
    encoding, channels, rate, _, align, bits = struct.unpack_from("<HHIIHH", fmt)
    if encoding == 65534:
        if len(fmt) < 40 or struct.unpack_from("<H", fmt, 18)[0] != 24:
            raise ValueError("Unsupported extensible format")
        if fmt[24:40] != bytes.fromhex("0100000000001000800000aa00389b71"):
            raise ValueError("Extensible WAV is not PCM")
    elif encoding != 1:
        raise ValueError("WAV is not PCM")
    if (channels, rate, bits, align) != (2, 48000, 24, 6) or len(pcm) % 6:
        raise ValueError("Expected 48 kHz, 24-bit stereo PCM")
    octets = np.frombuffer(pcm, dtype=np.uint8).reshape(-1, 2, 3).astype(np.int32)
    samples = octets[:, 0, 0] | (octets[:, 0, 1] << 8) | (octets[:, 0, 2] << 16)
    signed = (samples ^ 0x800000) - 0x800000
    if len(samples) > 600000:
        raise ValueError("Replay test supports at most 600000 samples")
    Path(output).write_text("".join(f"{v:06x}\n" for v in samples), encoding="ascii")
    print(json.dumps({"count": len(samples), "seconds": len(samples) / rate,
                      "left_dc_full_scale": float(signed.mean() / 8388608),
                      "left_rms_full_scale": float(np.sqrt(np.mean((signed / 8388608) ** 2)))}, indent=2))


def summarize(csv_path, detail_path, minimum_bars):
    values = np.loadtxt(csv_path, delimiter=",", skiprows=1)[:, 1:].astype(int)
    bars = np.zeros((len(values), 64), dtype=int)
    bars[:, ::2] = values
    bars[:, 1:63:2] = (values[:, :-1] + values[:, 1:]) // 2
    bars[:, 63] = values[:, 31]
    lengths = (bars >> 2) + (bars >> 4)
    if minimum_bars:
        lengths = np.where(values.any(axis=1)[:, None], np.maximum(lengths, 2), lengths)
    with Path(detail_path).open(encoding="ascii") as handle:
        detail = list(csv.DictReader(handle))
    targets = np.array([int(row["target"]) for row in detail])
    return {"video_frames": len(values), "target_saturation_percent": float((targets == 255).mean()*100),
            "mean_visible_bars": float((lengths > 0).sum(axis=1).mean()),
            "per_bar": [{"bar": i, "min_px": int(lengths[:, i].min()),
                         "max_px": int(lengths[:, i].max()),
                         "p05_p95_range_px": float(np.diff(np.percentile(lengths[:, i], [5, 95]))[0]),
                         "mean_frame_change_px": float(np.abs(np.diff(lengths[:, i])).mean())}
                        for i in range(64)]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("wav")
    prep.add_argument("output")
    compare = commands.add_parser("compare")
    for name in ("old", "old_detail", "new", "new_detail", "output"):
        compare.add_argument(name)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.wav, args.output)
    else:
        result = {"old": summarize(args.old, args.old_detail, False),
                  "new": summarize(args.new, args.new_detail, True)}
        Path(args.output).write_text(json.dumps(result, indent=2), encoding="utf-8")
        for key, value in result.items():
            print(key, {k: v for k, v in value.items() if k != "per_bar"})


if __name__ == "__main__":
    main()
