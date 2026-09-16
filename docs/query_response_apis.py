"""Replay only public GET reads found in the supplied response's StatsClient."""
import concurrent.futures, json
from archive import ROOT, fetch, save_json

TOKEN = '0x5ab000ff9B9FfE0349CE5ffA5fD86f217C3680F5'
WETH = '0x4200000000000000000000000000000000000006'
ENDPOINTS = {
    'stonkex': '/api/stonkex',
    'analytics': '/api/analytics',
    'volume': '/api/volume',
    'dex-prices': f'/api/dex-prices?addrs={WETH},{TOKEN}&minLiq=0&quotes={WETH},{TOKEN}',
}

def main():
    def query(item):
        name, path = item
        dest = ROOT / 'response-analysis/api' / (name + '.json')
        record = fetch('https://www.thestonks.exchange' + path, dest)
        record['method'] = 'GET'
        try:
            data = json.loads(dest.read_text(encoding='utf-8'))
            record['json_valid'] = True
            print(name, record['http_status'], 'keys:', list(data) if isinstance(data, dict) else type(data).__name__)
        except (ValueError, FileNotFoundError): record['json_valid'] = False
        return record
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: records = list(pool.map(query, ENDPOINTS.items()))
    save_json(ROOT / 'response-analysis/api-manifest.json', records)

if __name__ == '__main__': main()
