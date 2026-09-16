"""Archive the user-requested public documentation; run with py -3 docs/archive.py."""
import concurrent.futures, datetime, hashlib, html, json, pathlib, re, subprocess
from html.parser import HTMLParser

ROOT = pathlib.Path(__file__).resolve().parent
CONTRACTS = {
    'STONKEX': '0x5ab000ff9B9FfE0349CE5ffA5fD86f217C3680F5',
    'StonkLauncher2': '0x4714f6EC81639Ca59EEBE634490a4d8671DCe7B4',
    'StonkFeeLocker2': '0x71D1D363176723f85d98B8B430DF33cde89f0A7f',
    'StonkQuoteRegistry2': '0x4db9F13325A83662cf992184bc070755a212e95B',
    'StonkTradeRouter3': '0x01F178473DcaC0CE4b2B2111BecFB074b586dd12',
    'StonkQuoter': '0x2826DF040b68F528f5DEF00A5727e14691B755b4',
    'StonkDisperse': '0x3e3F3A9f15614FA40244219F025C88602db58e1c',
    'StonkFeeSplitter': '0xfBC9eE130f1CFeeb192b18CF1202865d757FA680',
}

class Extract(HTMLParser):
    def __init__(self):
        super().__init__(); self.text = []; self.skip = 0; self.sources = {}; self.abi = None; self.capture = False; self.links = []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ('script', 'style'): self.skip += 1
        if 'data-cname' in a and 'data-csource' in a: self.sources[a['data-cname']] = a['data-csource']
        if a.get('id') == 'js-copytextarea2': self.capture = True
        if tag == 'a' and 'href' in a: self.links.append(a['href'])
    def handle_endtag(self, tag):
        if tag in ('script', 'style'): self.skip = max(0, self.skip - 1)
        if tag == 'pre': self.capture = False
    def handle_data(self, data):
        if self.capture:
            try: self.abi = json.loads(data)
            except ValueError: pass
        if not self.skip and data.strip(): self.text.append(data.strip())

def save_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

def fetch(url, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(['curl.exe', '-L', '--max-time', '40', '--retry', '1', '-sS', '-D', str(dest.with_suffix('.headers.txt')), '-o', str(dest), '-w', '%{http_code}', url], capture_output=True, text=True)
    info = {'url': url, 'fetched_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'http_status': result.stdout, 'error': result.stderr, 'path': dest.relative_to(ROOT).as_posix()}
    if dest.exists(): info['sha256'] = hashlib.sha256(dest.read_bytes()).hexdigest()
    return info

def contract(item):
    name, address = item
    dest = ROOT / 'contracts' / name
    record = fetch('https://basescan.org/address/' + address + '#code', dest / 'page.html')
    record.update(name=name, address=address, chain_id=8453)
    parser = Extract()
    if (dest / 'page.html').exists(): parser.feed((dest / 'page.html').read_text(encoding='utf-8', errors='replace'))
    (dest / 'page.txt').write_text('\n'.join(parser.text), encoding='utf-8')
    for filename, content in parser.sources.items():
        target = (dest / 'sources' / filename).resolve()
        if not target.is_relative_to((dest / 'sources').resolve()): raise ValueError(filename)
        target.parent.mkdir(parents=True, exist_ok=True); target.write_text(content, encoding='utf-8')
    if parser.abi is not None: save_json(dest / 'abi.json', parser.abi)
    raw = (dest / 'page.html').read_text(encoding='utf-8', errors='replace') if (dest / 'page.html').exists() else ''
    implementations = sorted(set(a.lower() for a in re.findall(r'Implementation:</span>.{0,600}?data-highlight-target="(0x[a-fA-F0-9]{40})"', raw)))
    record.update(source_files=len(parser.sources), abi_saved=parser.abi is not None, implementations=implementations)
    save_json(dest / 'metadata.json', record)
    return record

def main():
    records = []
    for slug in ('about', 'stats'):
        dest = ROOT / 'site' / (slug + '.html')
        records.append(fetch('https://www.thestonks.exchange/' + slug, dest))
        parser = Extract(); parser.feed(dest.read_text(encoding='utf-8'))
        dest.with_suffix('.txt').write_text('\n'.join(parser.text), encoding='utf-8')
        save_json(dest.with_suffix('.links.json'), sorted(set(parser.links)))
    records.append(fetch('https://basescan.org/token/' + CONTRACTS['STONKEX'], ROOT / 'contracts' / 'STONKEX' / 'token.html'))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        contracts = list(executor.map(contract, CONTRACTS.items()))
    records.extend(contracts)
    impls = {a for r in contracts for a in r['implementations']}
    for address in sorted(impls): records.append(contract(('implementation-' + address, address)))
    save_json(ROOT / 'manifest.json', records)
    print(json.dumps([{'name': r.get('name', r['path']), 'http': r['http_status'], 'sources': r.get('source_files'), 'abi': r.get('abi_saved'), 'implementations': r.get('implementations')} for r in records], indent=2))

if __name__ == '__main__': main()
