"""检查去附加块、PCM 保真、重采样及转换失败不覆盖输出。"""
import importlib.util
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('normalize_wav', ROOT/'src/python/normalize_wav.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FFMPEG = shutil.which('ffmpeg') or 'E:/ffmpeg/bin/ffmpeg.exe'


class NormalizeWavTest(unittest.TestCase):
    def setUp(self):
        directory = ROOT/'prj/log/wav_canonical_conversion'
        directory.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=directory)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def test_metadata_removed_and_pcm_preserved(self):
        pcm = struct.pack('<hhhh', 4660, 22136, -32768, 32767)*128
        fmt = struct.pack('<4sIHHIIHH', b'fmt ', 16, 1, 2, 48000, 192000, 4, 16)
        junk = struct.pack('<4sI', b'JUNK', 3)+b'abc\0'
        body = b'WAVE'+fmt+junk+struct.pack('<4sI', b'data', len(pcm))+pcm
        source, output = self.directory/'with_junk.wav', self.directory/'plain.wav'
        source.write_bytes(b'RIFF'+struct.pack('<I', len(body))+body)
        frames = MODULE.normalize(source, output, FFMPEG)
        result = output.read_bytes()
        self.assertEqual(frames, len(pcm)//4)
        self.assertEqual(result[:44], struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', len(pcm)+36,
                         b'WAVE', b'fmt ', 16, 1, 2, 48000, 192000, 4, 16, b'data', len(pcm)))
        self.assertEqual(result[44:], pcm)

    def test_resample_mono(self):
        source, output = self.directory/'mono.wav', self.directory/'stereo.wav'
        with wave.open(str(source), 'wb') as wav:
            wav.setparams((1, 2, 24000, 0, 'NONE', 'not compressed'))
            wav.writeframes(struct.pack('<h', 1000)*2400)
        frames = MODULE.normalize(source, output, FFMPEG)
        self.assertEqual(frames, 4800)
        with wave.open(str(output), 'rb') as wav:
            self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate()), (2, 2, 48000))
        self.assertEqual(output.stat().st_size, 44+4*frames)

    def test_existing_output_and_failed_conversion(self):
        source, output = self.directory/'bad.wav', self.directory/'existing.wav'
        source.write_bytes(b'not an audio file')
        output.write_bytes(b'preserve existing output')
        with self.assertRaises(ValueError):
            MODULE.normalize(source, output, FFMPEG)
        with self.assertRaises(ValueError):
            MODULE.normalize(source, output, FFMPEG, force=True)
        self.assertEqual(output.read_bytes(), b'preserve existing output')


if __name__ == '__main__':
    unittest.main()
