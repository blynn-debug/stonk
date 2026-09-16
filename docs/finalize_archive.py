"""Extract local snapshots and verify the archive without refreshing network data."""
import hashlib, json, pathlib, re
from archive import ROOT, Extract, save_json

manifest = json.loads((ROOT / 'manifest.json').read_text(encoding='utf-8'))
for item in manifest:
    if 'name' not in item: continue
    raw = (ROOT / item['path']).read_text(encoding='utf-8')
    item['implementations'] = sorted(set(a.lower() for a in re.findall(r'Implementation:</span>.{0,600}?data-highlight-target="(0x[a-fA-F0-9]{40})"', raw)))
    if item['name'] == 'implementation-0x000100abaad02f1cfc8bbe32bd5a564817339e72':
        item['note'] = 'Supplementary address referenced in transaction rows; not a confirmed implementation of the requested contracts.'
    save_json((ROOT / item['path']).parent / 'metadata.json', item)
save_json(ROOT / 'manifest.json', manifest)

provided = ROOT / 'provided' / 'stonk_response.txt'
parser = Extract(); parser.feed(provided.read_text(encoding='utf-8-sig'))
(ROOT / 'provided' / 'stonk_response.extracted.txt').write_text('\n'.join(parser.text), encoding='utf-8')
source = pathlib.Path('C:/Users/user/OneDrive/바탕 화면/stonk_response.txt')
assert source.read_bytes() == provided.read_bytes(), 'Local copy differs'
save_json(ROOT / 'provided' / 'local-file.json', {
    'requested_name': 'desktop > stonk.txt', 'actual_source': str(source),
    'saved_as': 'provided/stonk_response.txt', 'bytes': provided.stat().st_size,
    'sha256': hashlib.sha256(provided.read_bytes()).hexdigest(),
    'title': re.findall(r'<title>(.*?)</title>', provided.read_text(encoding='utf-8-sig')),
    'copy_verified_identical': True,
})
for item in manifest:
    assert hashlib.sha256((ROOT / item['path']).read_bytes()).hexdigest() == item['sha256']
    if item.get('abi_saved'):
        assert isinstance(json.loads((ROOT / item['path']).with_name('abi.json').read_text(encoding='utf-8')), list)
    if 'source_files' in item:
        assert len(list((ROOT / item['path']).parent.joinpath('sources').rglob('*.sol'))) == item['source_files']
checksums = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name != 'checksums.json' and '__pycache__' not in p.parts}
save_json(ROOT / 'checksums.json', checksums)
print('Verified original copy, HTTP snapshot hashes, ABI JSON, and Solidity file counts.')
print('Archived files:', len(checksums))
print('Solidity files:', len(list(ROOT.rglob('*.sol'))))
