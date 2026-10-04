"""把普通音乐转换成板级读取器接受的 44 字节头 PCM WAV。"""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


def normalize(source, output, ffmpeg, force=False):
    source, output = Path(source).resolve(), Path(output).resolve()
    if not source.is_file():
        raise ValueError(f'input does not exist: {source}')
    if output.exists() and not force:
        raise ValueError(f'output exists; use --force to replace: {output}')
    output.parent.mkdir(parents=True, exist_ok=True)
    # 在输出目录暂存，转换/校验失败不会破坏已有输出；提交时同文件系统替换。
    with tempfile.TemporaryDirectory(prefix='normalize-wav-', dir=output.parent) as directory:
        raw = Path(directory)/'audio.pcm'
        result = subprocess.run([str(ffmpeg), '-nostdin', '-hide_banner', '-loglevel', 'error',
                                 '-i', str(source), '-map', '0:a:0', '-vn', '-ac', '2', '-ar', '48000',
                                 '-c:a', 'pcm_s16le', '-f', 's16le', str(raw)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise ValueError('ffmpeg failed: '+result.stderr.decode(errors='replace')[-2000:])
        size = raw.stat().st_size
        if size == 0 or size % 4 or size > 0xffffffff-36:
            raise ValueError('PCM must contain complete stereo frames and fit the RIFF size field')
        normalized = Path(directory)/'canonical.wav'
        with normalized.open('wb') as target, raw.open('rb') as pcm:
            target.write(struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', size+36, b'WAVE', b'fmt ',
                                     16, 1, 2, 48000, 192000, 4, 16, b'data', size))
            shutil.copyfileobj(pcm, target)
        normalized.replace(output)
    return size//4


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg') or 'E:/ffmpeg/bin/ffmpeg.exe')
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    try:
        frames = normalize(args.source, args.output, args.ffmpeg, args.force)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error)+'\n')
    print(f'PASS canonical WAV: {frames} frames, {frames/48000:.3f} seconds; {args.output}')


if __name__ == '__main__':
    main()
