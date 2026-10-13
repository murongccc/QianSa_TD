"""只读分析三/四指实测抓包；结果写入日志，不修改主工程。"""
from pathlib import Path
from collections import Counter
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'prj/log/three_touch_capture_20261013'
OUT.mkdir(parents=True, exist_ok=True)
results = []
for name in ['touch_01_three_down_release', 'touch_02_third_move',
             'touch_03_contact_replace', 'touch_04_four_limit']:
    path = Path('C:/Users/murong/Desktop') / (name + '.txt')
    source = path.read_bytes()
    text = source.decode('utf-8-sig')
    tokens = text.split()
    if any(not re.fullmatch(r'[0-9a-fA-F]{2}', t) for t in tokens):
        raise ValueError(f'{name}: contains non-HEX tokens')
    data = bytes(int(t, 16) for t in tokens)
    frames = []
    skipped = bad_sum = incomplete = 0
    pos = 0
    while pos < len(data):
        if data[pos:pos+3] != b'\x57\xab\x88':
            pos += 1
            skipped += 1
            continue
        if pos + 4 > len(data) or pos + 4 + data[pos+3] > len(data):
            incomplete += 1
            break
        length = data[pos+3]
        body = data[pos+4:pos+4+length]
        if length != 57:
            raise ValueError(f'{name}: unexpected length {length} at {pos}')
        if (sum(body[1:-1]) & 255) != body[-1]:
            bad_sum += 1
        else:
            records = []
            count = body[54]
            for slot in range(10):
                record = body[2+5*slot:7+5*slot]
                if slot < count or any(record):
                    records.append({'slot': slot, 'id': record[0] >> 4,
                                    'down': record[0] & 1, 'reserved': record[0] & 14,
                                    'x': int.from_bytes(record[1:3], 'little'),
                                    'y': int.from_bytes(record[3:5], 'little')})
            frames.append({'offset': pos, 'seq': body[55], 'count': count,
                           'ident': body[0], 'report_id': body[1],
                           'trailer': list(body[52:54]), 'records': records})
        pos += 4 + length
    histogram = Counter(f['count'] for f in frames)
    active_histogram = Counter(sum(r['down'] for r in f['records']) for f in frames)
    transitions = []
    last = None
    for i, f in enumerate(frames):
        signature = [(r['id'], r['down']) for r in f['records']]
        if signature != last:
            transitions.append({'frame': i, **f})
            last = signature
    positions = {}
    for f in frames:
        active_ids = tuple(r['id'] for r in f['records'] if r['down'])
        if len(active_ids) >= 3:
            group = positions.setdefault(str(active_ids), {})
            for r in f['records']:
                if r['down']:
                    group.setdefault(str(r['id']), set()).add((r['x'], r['y']))
    movement = {g: {identity: {'distinct_positions': len(points),
                             'x_range': [min(x for x,y in points), max(x for x,y in points)],
                             'y_range': [min(y for x,y in points), max(y for x,y in points)]}
                    for identity, points in records.items()} for g, records in positions.items()}
    result = {'file': str(path), 'sha256': hashlib.sha256(source).hexdigest(),
              'bytes': len(data), 'valid_frames': len(frames), 'bad_checksum': bad_sum,
              'skipped_bytes': skipped, 'incomplete_frames': incomplete,
              'sequence_gaps': sum(b['seq'] != (a['seq']+1)&255 for a,b in zip(frames,frames[1:])),
              'record_count_histogram': dict(histogram), 'active_count_histogram': dict(active_histogram),
              'invalid_reserved_records': sum(bool(r['reserved']) for f in frames for r in f['records']),
              'duplicate_id_frames': sum(len({r['id'] for r in f['records']}) != len(f['records']) for f in frames),
              'record_count_mismatch_frames': sum(len(f['records']) != f['count'] for f in frames),
              'ident_report_trailers': sorted({(f['ident'],f['report_id'],*f['trailer']) for f in frames}),
              'transitions': transitions, 'movement_with_three_or_more': movement}
    results.append(result)
    print(name, json.dumps({k:v for k,v in result.items() if k not in ['file','sha256','transitions','movement_with_three_or_more']}, ensure_ascii=False))
    print('transitions:', json.dumps(transitions, ensure_ascii=False))
    print('movement:', json.dumps(movement, ensure_ascii=False))
(OUT/'analysis.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
print('Report:', OUT/'analysis.json')
