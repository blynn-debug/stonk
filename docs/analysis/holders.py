import concurrent.futures, json, re, subprocess, time
from html.parser import HTMLParser
from collect import ROOT, RAW, TOKEN, rpc, save

class Table(HTMLParser):
    def __init__(self): super().__init__(); self.rows=[]; self.row=None; self.cell=None
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if tag=='tr': self.row={'cells':[],'addresses':[]}
        if self.row is not None:
            if tag=='td': self.cell=[]
            for key in ('data-clipboard-text','data-highlight-target'):
                if re.fullmatch('0x[0-9a-fA-F]{40}',a.get(key,'')): self.row['addresses'].append(a[key].lower())
            for match in re.findall(r'(?:a=|/address/)(0x[0-9a-fA-F]{40})',a.get('href','')): self.row['addresses'].append(match.lower())
    def handle_data(self,text):
        if self.cell is not None:self.cell.append(text)
    def handle_endtag(self,tag):
        if tag=='td' and self.row is not None and self.cell is not None:
            self.row['cells'].append(''.join(self.cell).strip());self.cell=None
        if tag=='tr' and self.row is not None:
            if self.row['cells']:self.rows.append(self.row)
            self.row=None

def main():
    holders=[]
    for page in range(1,6):
        path=RAW/f'holders-page{page}.html'
        if not path.exists():
            url=f'https://basescan.org/token/generic-tokenholders2?a={TOKEN}&s=1000000000000000000000000000&p={page}'
            p=subprocess.run(['curl.exe','-sS','-L','--max-time','45',url],capture_output=True,check=True)
            path.write_bytes(p.stdout)
        parser=Table();parser.feed(path.read_text(encoding='utf-8'))
        for row in parser.rows:
            cells=row['cells']
            if cells[0].isdigit() and row['addresses']:
                holders.append({'explorer_rank':int(cells[0]),'address':row['addresses'][0],'cells':cells})
    save('holder-candidates',holders)
    print('candidates',len(holders),holders[:2],flush=True)
    snapshot=json.loads((RAW/'snapshot.json').read_text())
    block=snapshot['hex']
    def read(holder):
        a=holder['address']
        balance=rpc('eth_call',[{'to':TOKEN,'data':'0x70a08231'+a[2:].zfill(64)},block])
        code=rpc('eth_getCode',[a,block])
        return dict(holder,raw_balance=str(int(balance,16)),code=code)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(read,holders))
    results.sort(key=lambda x:int(x['raw_balance']),reverse=True)
    save('holders-verified',results)
    receipt=rpc('eth_getTransactionReceipt',['0x03615f1a465b92bbbe75d369b1df35b12758a22af8a5ac5fecb254bb5b13feb6'])
    save('creation-receipt',receipt)
    save('creation-transaction',rpc('eth_getTransactionByHash',[receipt['transactionHash']]))
    print('deployment block',int(receipt['blockNumber'],16),'logs',len(receipt['logs']),flush=True)

if __name__=='__main__':main()
