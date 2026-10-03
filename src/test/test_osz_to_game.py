"""资源转换边界回归；使用合成资源包，另支持真实谱面的独立逐条核对。"""
import argparse
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import wave
import zipfile

ROOT = Path(__file__).resolve().parents[2]
TEST_OUTPUT = ROOT / 'prj/log/rhythm_converter_tests'
spec = importlib.util.spec_from_file_location('osz_to_game', ROOT / 'src/python/osz_to_game.py')
game = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = game
spec.loader.exec_module(game)


def source(objects='64,192,100,1,0,0:0:0:0:\n192,192,200,128,0,400:0:0:0:0:', mode=3, keys=4,
           audio='audio.wav', lead_in=0):
    return (f'osu file format v14\n[General]\nAudioFilename:{audio}\nMode:{mode}\nAudioLeadIn:{lead_in}\n'
            f'[Metadata]\nTitle:Example\nArtist:Tester\nVersion:Normal\n[Difficulty]\nCircleSize:{keys}\n'
            f'[HitObjects]\n{objects}\n')


class ConversionTests(unittest.TestCase):
    def test_binary_layout(self):
        chart = game.parse_chart(source())
        binary = game.encode_chart(chart, 48000, 48)
        self.assertEqual(len(binary), 80)
        self.assertEqual(struct.unpack_from('<4sIIIIi', binary), (b'R4B1', 48000, 48000, 2, 1, 48))
        self.assertEqual(binary[24:48], b'Example' + bytes(17))
        self.assertEqual(binary[48:64], b'Normal' + bytes(10))
        self.assertEqual(binary[64:72], struct.pack('<I', 4800) + bytes(4))
        self.assertEqual(binary[72:80], struct.pack('<I', 9600) + (9600).to_bytes(3, 'little') + b'\x05')

    def test_lane_boundaries_and_sort(self):
        xs = [512, 448, 384, 383, 256, 255, 128, 127, 0]
        chart = game.parse_chart(source('\n'.join(f'{x},0,{100 + i * 3000},1,0' for i, x in enumerate(xs))))
        self.assertEqual([n.lane for n in chart.notes], [3, 3, 3, 2, 2, 1, 1, 0, 0])
        chart = game.parse_chart(source('448,0,200,1,0\n192,0,100,1,0\n64,0,100,1,0'))
        self.assertEqual([(n.start, n.lane) for n in chart.notes], [(4800, 0), (4800, 1), (9600, 3)])

    def test_non_native_rejected(self):
        for mode, keys in [(0, 4), (3, 7), (3, 3.9)]:
            with self.subTest(mode=mode, keys=keys), self.assertRaises(game.ChartError):
                game.parse_chart(source(mode=mode, keys=keys))

    def test_unsupported_types_rejected(self):
        for kind in [0, 2, 8, 129, 256, -1]:
            with self.subTest(kind=kind), self.assertRaises(game.ChartError):
                game.parse_chart(source(f'64,0,100,{kind},0,200:0:0:0:0:'))

    def test_invalid_records(self):
        for obj in ['64,0', '64,0,-1,1,0', '-1,0,100,1,0', '513,0,100,1,0',
                    '64,0,100,128,0', '64,0,100,128,0,100:', '64,0,100,128,0,99:',
                    '64,0,100,128,0,400000:', '64,0,100000000,1,0']:
            with self.subTest(obj=obj), self.assertRaises(game.ChartError):
                game.parse_chart(source(obj))

    def test_combo_flags_allowed(self):
        chart = game.parse_chart(source('64,0,100,117,0'))
        self.assertEqual(chart.notes, [game.Note(0, 4800)])

    def test_same_lane_conflicts(self):
        for objects in ['64,0,100,1,0\n64,0,100,1,0',
                        '64,0,100,128,0,400:\n64,0,399,1,0']:
            with self.assertRaises(game.ChartError):
                game.parse_chart(source(objects))
        self.assertEqual(len(game.parse_chart(source('64,0,100,128,0,400:\n64,0,400,1,0')).notes), 2)

    def test_capacity_and_closed_interval(self):
        objects = '\n'.join(f'64,0,{i * 100},1,0' for i in range(8))
        self.assertEqual(game.validate_notes(game.parse_chart(source(objects)).notes)[0], 8)
        with self.assertRaises(game.ChartError):
            game.parse_chart(source(objects + '\n64,0,800,1,0'))
        # 第九个恰好进入时，第一个迟判窗口尚未结束：同刻按闭区间计算。
        notes = [game.Note(0, i * 100) for i in range(8)] + [game.Note(0, game.LOOKAHEAD + game.LATE_WINDOW)]
        with self.assertRaises(game.ChartError):
            game.validate_notes(notes)
        notes[-1] = game.Note(0, notes[-1].start + 1)
        self.assertEqual(game.validate_notes(notes)[0], 8)

    def test_offsets_and_audio_bounds(self):
        chart = game.parse_chart(source())
        for offset, frames in [(-4801, 48000), (2 ** 31, 48000), (0, 19200), (48000, 48000)]:
            with self.subTest(offset=offset, frames=frames), self.assertRaises(game.ChartError):
                game.encode_chart(chart, frames, offset)
        game.encode_chart(chart, 19201)
        game.encode_chart(chart, 48000, -4800)

    def test_empty_and_count_limit(self):
        with self.assertRaises(game.ChartError):
            game.parse_chart(source(''))
        with self.assertRaises(game.ChartError):
            game.validate_notes([game.Note(0, i * 200000) for i in range(65536)])

    def test_relative_audio_paths(self):
        chart = game.parse_chart(source(audio='../audio.wav'), 'charts/map.osu')
        self.assertEqual(chart.audio_member, 'audio.wav')
        for path in ['../audio.wav', '/audio.wav', 'C:\\audio.wav', '']:
            with self.subTest(path=path), self.assertRaises(game.ChartError):
                game.parse_chart(source(audio=path))

    def test_ascii_and_lead_in(self):
        self.assertEqual(game.ascii_field('汉字abc', 5), b'??ab\0')
        for lead_in in [-1, 2001]:
            with self.assertRaises(game.ChartError):
                game.parse_chart(source(lead_in=lead_in))

    def test_package_inspection(self):
        TEST_OUTPUT.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=TEST_OUTPUT) as tmp:
            path = Path(tmp) / 'sample.osz'
            with zipfile.ZipFile(path, 'w') as package:
                package.writestr('good.osu', source())
                package.writestr('standard.osu', source(mode=0))
                package.writestr('missing.osu', source(audio='absent.mp3'))
                package.writestr('audio.wav', b'test')
            accepted, rejected = game.inspect_package(path)
            self.assertEqual(len(accepted), 1)
            self.assertEqual(len(rejected), 2)

    def test_conversion_publication_and_failure(self):
        TEST_OUTPUT.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=TEST_OUTPUT) as tmp:
            path = Path(tmp) / 'sample.osz'
            output = Path(tmp) / 'output'
            with zipfile.ZipFile(path, 'w') as package:
                package.writestr('good.osu', source())
                package.writestr('audio.wav', b'test')

            def fake_decode(package, chart, target, ffmpeg):
                with wave.open(str(target), 'wb') as audio:
                    audio.setparams((2, 2, 48000, 0, 'NONE', 'not compressed'))
                    audio.writeframes(bytes(48000 * 4))
                return 48000

            with mock.patch.object(game, 'decode_audio', side_effect=fake_decode):
                report = game.convert(path, 'Normal', output, 'unused')
            self.assertEqual(report['notes'], 2)
            old = {name: p.read_bytes() for name in ['GAME.BIN', 'GAME.WAV', 'conversion-report.json']
                   for p in [output / name]}
            with self.assertRaises(game.ChartError):
                game.convert(path, 'Normal', output, 'unused')
            with mock.patch.object(game, 'decode_audio', side_effect=game.ChartError('decode failure')):
                with self.assertRaises(game.ChartError):
                    game.convert(path, 'Normal', output, 'unused', force=True)
            for name, contents in old.items():
                self.assertEqual((output / name).read_bytes(), contents)
            self.assertFalse(list(output.glob('.rhythm-*')))
            with self.assertRaises(game.ChartError):
                game.convert(path, 'Missing', output, 'unused')

    def test_ambiguous_difficulty_rejected(self):
        TEST_OUTPUT.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=TEST_OUTPUT) as tmp:
            path = Path(tmp) / 'sample.osz'
            with zipfile.ZipFile(path, 'w') as package:
                package.writestr('a.osu', source())
                package.writestr('b.osu', source())
                package.writestr('audio.wav', b'test')
            with self.assertRaises(game.ChartError):
                game.convert(path, 'Normal', Path(tmp) / 'out', 'unused')


def verify_real(package_path, output):
    # 独立解析源文件和生成的二进制，不使用转换器的 parse/encode 作为参考。
    report = json.loads((output / 'conversion-report.json').read_text(encoding='utf-8'))
    with zipfile.ZipFile(package_path) as package:
        text = package.read(report['member']).decode('utf-8-sig')
    raw_objects = text.split('[HitObjects]', 1)[1]
    expected = []
    for line in raw_objects.splitlines():
        if not line.strip() or line.strip().startswith('//'):
            continue
        fields = line.strip().split(',')
        x, start, flags = int(fields[0]), int(fields[2]), int(fields[3])
        end = int(fields[5].split(':')[0]) if flags & 128 else start
        expected.append((start * 48, (end - start) * 48, min(3, x // 128)))
    expected.sort(key=lambda n: (n[0], n[2]))
    binary = (output / 'GAME.BIN').read_bytes()
    magic, rate, frames, count, holds, offset = struct.unpack_from('<4sIIIIi', binary)
    assert magic == b'R4B1' and rate == 48000 and offset == 0
    assert len(binary) == 64 + count * 8
    actual = []
    for index in range(count):
        record = binary[64 + index * 8:72 + index * 8]
        start = int.from_bytes(record[:4], 'little')
        duration = int.from_bytes(record[4:7], 'little')
        assert record[7] & 0xf0 == 0
        assert record[7] >> 2 == int(duration > 0)
        actual.append((start, duration, record[7] & 3))
    assert actual == expected, 'source and generated chart differ'
    assert count == 413 and holds == 49 and sum(n[1] > 0 for n in actual) == 49
    header = (output / 'GAME.WAV').read_bytes()[:44]
    assert struct.unpack('<4sI4s4sIHHIIHH4sI', header) == (
        b'RIFF', frames * 4 + 36, b'WAVE', b'fmt ', 16, 1, 2, 48000, 192000, 4, 16, b'data', frames * 4)
    with wave.open(str(output / 'GAME.WAV'), 'rb') as audio:
        assert audio.getnframes() == frames == 4323421
    for name, digest in report['outputs_sha256'].items():
        assert game.sha256(output / name) == digest
    assert game.sha256(package_path) == report['source_sha256']
    print(f'PASS real chart: {count} exact records, {holds} holds, {frames} PCM frames, hashes verified')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--verify-real':
        parser = argparse.ArgumentParser()
        parser.add_argument('--verify-real', type=Path)
        parser.add_argument('--output', type=Path, required=True)
        args = parser.parse_args()
        verify_real(args.verify_real, args.output)
    else:
        unittest.main()
