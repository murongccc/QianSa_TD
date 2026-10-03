"""将原生 osu!mania 4K 资源包转换为 SD 音游资源（R4B1 / PCM WAV）。"""
import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import struct
import subprocess
import tempfile
import wave
import zipfile

SAMPLE_RATE = 48000
HEADER = struct.Struct('<4sIIIIi24s16s')
MAGIC = b'R4B1'
LOOKAHEAD = 96000
LATE_WINDOW = 7200
LANE_CAPACITY = 8
MAX_NOTES = 65535


class ChartError(ValueError):
    """输入资源不满足板级协议。"""


@dataclass(frozen=True)
class Note:
    lane: int
    start: int
    duration: int = 0

    @property
    def end(self):
        return self.start + self.duration


@dataclass
class Chart:
    member: str
    metadata: dict
    audio_member: str
    notes: list


def _integer(value, name):
    try:
        return int(value)
    except (ValueError, TypeError) as exc:
        raise ChartError(f'{name}: expected integer, got {value!r}') from exc


def _package_path(chart_member, filename):
    # 只读取 ZIP 成员，不向磁盘解压；拒绝越出包根目录的相对路径。
    filename = filename.replace('\\', '/')
    if not filename or filename.startswith('/') or ':' in filename:
        raise ChartError('AudioFilename must be a relative package path')
    name = posixpath.normpath(posixpath.join(str(PurePosixPath(chart_member).parent), filename))
    if name == '..' or name.startswith('../'):
        raise ChartError('AudioFilename escapes package root')
    return name


def parse_chart(text, member='<chart>.osu'):
    sections = {}
    section = None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        if line.startswith('[') and line.endswith(']'):
            section = line[1:-1]
            sections.setdefault(section, [])
        elif section:
            sections[section].append(line)
    fields = {}
    for name in ('General', 'Metadata', 'Difficulty'):
        fields[name] = {}
        for line in sections.get(name, []):
            if ':' in line:
                key, value = line.split(':', 1)
                fields[name][key.strip()] = value.strip()
    if _integer(fields['General'].get('Mode'), 'Mode') != 3:
        raise ChartError('only native osu!mania Mode:3 is supported')
    try:
        four_keys = float(fields['Difficulty'].get('CircleSize', 'nan')) == 4
    except ValueError:
        four_keys = False
    if not four_keys:
        raise ChartError('only native CircleSize:4 is supported')
    lead_in = _integer(fields['General'].get('AudioLeadIn', '0'), 'AudioLeadIn')
    if lead_in < 0:
        raise ChartError('AudioLeadIn must not be negative')
    # 首版预滚固定为两秒，源谱要求更长的等待时拒绝，避免悄悄截断。
    if lead_in > 2000:
        raise ChartError('AudioLeadIn exceeds the fixed 2000 ms pre-roll')
    notes = []
    for number, line in enumerate(sections.get('HitObjects', []), 1):
        values = line.split(',')
        where = f'{member}: HitObject {number}'
        if len(values) < 5:
            raise ChartError(f'{where}: incomplete record')
        x = _integer(values[0], where + ' x')
        start_ms = _integer(values[2], where + ' time')
        flags = _integer(values[3], where + ' type')
        if not 0 <= x <= 512 or start_ms < 0 or not 0 <= flags <= 255:
            raise ChartError(f'{where}: invalid coordinate/time/type')
        # 新连击和颜色位不影响音符类型；不将滑条、转盘或混合类型改成 Tap。
        kind = flags & 0x8b
        if kind == 1:
            duration_ms = 0
        elif kind == 128:
            if len(values) < 6:
                raise ChartError(f'{where}: missing hold end')
            end_ms = _integer(values[5].split(':', 1)[0], where + ' hold end')
            duration_ms = end_ms - start_ms
            if duration_ms <= 0:
                raise ChartError(f'{where}: hold end must follow head')
        else:
            raise ChartError(f'{where}: unsupported note type {flags}')
        note = Note(min(3, x * 4 // 512), start_ms * 48, duration_ms * 48)
        if note.start > 0xffffffff or note.end > 0xffffffff or note.duration > 0xffffff:
            raise ChartError(f'{where}: time exceeds R4B1 capacity')
        notes.append(note)
    notes.sort(key=lambda n: (n.start, n.lane))
    chart = Chart(member, fields['Metadata'],
                  _package_path(member, fields['General'].get('AudioFilename', '')), notes)
    validate_notes(notes)
    return chart


def validate_notes(notes, offset=0, song_frames=None):
    if not 1 <= len(notes) <= MAX_NOTES:
        raise ChartError(f'note count must be 1..{MAX_NOTES}')
    if not -(1 << 31) <= offset < (1 << 31):
        raise ChartError('offset exceeds signed 32-bit samples')
    previous = [None] * 4
    events = [[] for _ in range(4)]
    for note in notes:
        old = previous[note.lane]
        if old and (old.start == note.start or old.end > note.start):
            raise ChartError(f'lane {note.lane + 1}: duplicate head or overlapping hold at {note.start} samples')
        if note.start + offset < 0 or note.end + offset > 0xffffffff:
            raise ChartError('offset moves a note outside the unsigned song timeline')
        if song_frames is not None and note.end + offset >= song_frames:
            raise ChartError('note reaches beyond the last audio sample')
        previous[note.lane] = note
        # 保守地将整个 Hold 留在活动队列直到尾部加迟判窗口。
        # 同时刻先加入后移除，覆盖闭区间边界。
        events[note.lane].extend([(note.start - LOOKAHEAD, 0, 1), (note.end + LATE_WINDOW, 1, -1)])
    peaks = []
    for lane, lane_events in enumerate(events):
        active = peak = 0
        for _, _, delta in sorted(lane_events):
            active += delta
            peak = max(peak, active)
        if peak > LANE_CAPACITY:
            raise ChartError(f'lane {lane + 1}: needs {peak} active slots, capacity is {LANE_CAPACITY}')
        peaks.append(peak)
    return peaks


def ascii_field(text, width):
    # 板级首版只有 ASCII 字库；报告保留完整原始 Unicode 名称。
    raw = text.encode('ascii', errors='replace')[:width - 1]
    return raw.ljust(width, b'\0')


def encode_chart(chart, song_frames, offset=0):
    validate_notes(chart.notes, offset, song_frames)
    if not 1 <= song_frames <= 0xffffffff:
        raise ChartError('audio frame count exceeds R4B1 capacity')
    holds = sum(n.duration > 0 for n in chart.notes)
    result = bytearray(HEADER.pack(MAGIC, SAMPLE_RATE, song_frames, len(chart.notes), holds, offset,
                                  ascii_field(chart.metadata.get('Title', ''), 24),
                                  ascii_field(chart.metadata.get('Version', ''), 16)))
    for note in chart.notes:
        result.extend(struct.pack('<I', note.start))
        result.extend(note.duration.to_bytes(3, 'little'))
        result.append(note.lane | (4 if note.duration else 0))
    return bytes(result)


def inspect_package(path):
    charts, rejected = [], []
    with zipfile.ZipFile(path) as package:
        names = package.namelist()
        if len(names) != len(set(names)):
            raise ChartError('package contains duplicate member names')
        for member in names:
            if member.lower().endswith('.osu'):
                try:
                    chart = parse_chart(package.read(member).decode('utf-8-sig'), member)
                    if chart.audio_member not in names:
                        raise ChartError(f'audio member not found: {chart.audio_member}')
                    charts.append(chart)
                except (ChartError, UnicodeError) as exc:
                    rejected.append({'member': member, 'reason': str(exc)})
    return charts, rejected


def chart_summary(chart):
    counts = Counter(n.lane for n in chart.notes)
    holds = sum(n.duration > 0 for n in chart.notes)
    return {'member': chart.member, 'title': chart.metadata.get('Title', ''),
            'artist': chart.metadata.get('Artist', ''), 'difficulty': chart.metadata.get('Version', ''),
            'audio_member': chart.audio_member, 'notes': len(chart.notes),
            'taps': len(chart.notes) - holds, 'holds': holds,
            'lane_counts': [counts[lane] for lane in range(4)],
            'active_slot_peaks': validate_notes(chart.notes),
            'first_note_samples': chart.notes[0].start,
            'last_tail_samples': max(n.end for n in chart.notes)}


def decode_audio(package_path, chart, output, ffmpeg):
    # 临时源文件放在工作输出目录；无需解压其他包成员或修改源资源包。
    with zipfile.ZipFile(package_path) as package:
        source = output.parent / ('source' + PurePosixPath(chart.audio_member).suffix)
        with package.open(chart.audio_member) as src, source.open('wb') as dst:
            shutil.copyfileobj(src, dst)
    raw = output.parent / 'audio.pcm'
    result = subprocess.run([str(ffmpeg), '-nostdin', '-hide_banner', '-loglevel', 'error',
                             '-i', str(source), '-map', '0:a:0', '-ar', str(SAMPLE_RATE),
                             '-ac', '2', '-c:a', 'pcm_s16le', '-f', 's16le', '-y', str(raw)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=300)
    if result.returncode:
        raise ChartError('ffmpeg decode failed: ' + result.stderr.decode(errors='replace')[-2000:])
    size = raw.stat().st_size
    if not size or size % 4 or size > 0xffffffff - 36:
        raise ChartError('invalid PCM length or RIFF size overflow')
    # 自行包装规范的 44 字节 WAV 头，避免 FFmpeg 写入 extensible/附加元数据。
    with output.open('wb') as target:
        target.write(struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', size + 36, b'WAVE', b'fmt ',
                                 16, 1, 2, SAMPLE_RATE, SAMPLE_RATE * 4, 4, 16, b'data', size))
        with raw.open('rb') as pcm:
            shutil.copyfileobj(pcm, target)
    with wave.open(str(output), 'rb') as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()) != (2, 2, SAMPLE_RATE, size // 4):
            raise ChartError('generated WAV verification failed')
    return size // 4


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def convert(package_path, difficulty, output, ffmpeg, offset=0, force=False):
    charts, rejected = inspect_package(package_path)
    matches = [c for c in charts if c.metadata.get('Version') == difficulty]
    if len(matches) != 1:
        raise ChartError(f'difficulty must match exactly one supported chart: {difficulty!r}; '
                         f'available: {[c.metadata.get("Version") for c in charts]}; rejected: {rejected}')
    chart = matches[0]
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    names = ['GAME.BIN', 'GAME.WAV', 'conversion-report.json']
    if not force and any((output / name).exists() for name in names):
        raise ChartError('output already exists; choose a new directory or explicitly use --force')
    with tempfile.TemporaryDirectory(prefix='.rhythm-', dir=output) as temp_name:
        temp = Path(temp_name)
        frames = decode_audio(package_path, chart, temp / 'GAME.WAV', ffmpeg)
        binary = encode_chart(chart, frames, offset)
        (temp / 'GAME.BIN').write_bytes(binary)
        report = chart_summary(chart)
        report.update({'format': 'R4B1', 'sample_rate': SAMPLE_RATE, 'song_frames': frames,
                       'song_seconds': frames / SAMPLE_RATE, 'offset_samples': offset,
                       'source_sha256': sha256(package_path),
                       'outputs_sha256': {name: sha256(temp / name) for name in names[:2]},
                       'binary_bytes': len(binary), 'wav_bytes': (temp / 'GAME.WAV').stat().st_size,
                       'ignored_features': ['scroll velocity', 'skin', 'storyboard', 'hitsounds'],
                       'notes_preserved': True})
        (temp / names[2]).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        # 所有校验完成后才发布结果；转换失败时保留原有输出。
        for name in names:
            os.replace(temp / name, output / name)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    inspect = commands.add_parser('inspect', help='list compatible difficulties and rejection reasons')
    inspect.add_argument('package', type=Path)
    build = commands.add_parser('convert', help='build one GAME.BIN / GAME.WAV pair')
    build.add_argument('package', type=Path)
    build.add_argument('--difficulty', required=True)
    build.add_argument('--output', type=Path, required=True)
    build.add_argument('--ffmpeg', type=Path, default=Path(shutil.which('ffmpeg') or 'E:/ffmpeg/bin/ffmpeg.exe'))
    build.add_argument('--offset-ms', type=int, default=0, help='positive values delay all notes')
    build.add_argument('--force', action='store_true', help='explicitly replace existing generated output')
    args = parser.parse_args()
    try:
        if args.command == 'inspect':
            charts, rejected = inspect_package(args.package)
            result = {'compatible': [chart_summary(c) for c in charts], 'rejected': rejected}
        else:
            result = convert(args.package, args.difficulty, args.output, args.ffmpeg,
                             args.offset_ms * 48, args.force)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ChartError, OSError, zipfile.BadZipFile, subprocess.TimeoutExpired) as exc:
        parser.exit(1, f'ERROR: {exc}\n')


if __name__ == '__main__':
    main()
