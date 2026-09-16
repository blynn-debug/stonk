"""Follow script references in the supplied HTTP response, then inspect read APIs."""
import concurrent.futures, json, re
from html.parser import HTMLParser
from urllib.parse import urljoin
from archive import ROOT, fetch, save_json

class Scripts(HTMLParser):
    def __init__(self): super().__init__(); self.urls = set()
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'script' and a.get('src'): self.urls.add(urljoin('https://www.thestonks.exchange', a['src']))

def main():
    raw = (ROOT / 'provided/stonk_response.txt').read_text(encoding='utf-8-sig')
    parser = Scripts(); parser.feed(raw)
    print('HTML document titles:', json.dumps(re.findall(r'<title>(.*?)</title>', raw)))
    print('Referenced script files:', len(parser.urls))
    def download(url): return fetch(url, ROOT / 'response-analysis/scripts' / url.rsplit('/', 1)[-1])
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool: records = list(pool.map(download, sorted(parser.urls)))
    save_json(ROOT / 'response-analysis/scripts-manifest.json', records)
    for record in records:
        text = (ROOT / record['path']).read_text(encoding='utf-8', errors='replace')
        snippets = [text[max(0,m.start()-180):m.end()+250] for m in re.finditer(r'/api/|functionName:"(?:totalSupply|balanceOf)|buyback|totalBurned', text)]
        if snippets:
            (ROOT / record['path']).with_suffix('.snippets.txt').write_text('\n\n'.join(snippets), encoding='utf-8')
            print(record['path'], 'matches:', len(snippets))

if __name__ == '__main__': main()
