"""Validate financial output invariants and PDF appendices before publication."""
import csv,hashlib,json,pathlib,re
from decimal import Decimal as D
from pypdf import PdfReader
from collect import ROOT,RAW,save

def main():
    summary=json.loads((RAW/'reconstruction-summary.json').read_text())
    holders=json.loads((RAW/'holders-verified.json').read_text())
    assert len(holders)==125 and all(h['balance_verified'] for h in holders)
    assert summary['minted_raw']==str(10**27)
    coverage=json.loads((RAW/'log-coverage.json').read_text());ranges=[]
    for p in sorted((RAW/'logs').glob('*.json')):
        a,b=map(int,p.stem.split('-'));ranges.append((a,b))
    assert len(ranges)==coverage['ranges'] and ranges[0][0]==coverage['fromBlock'] and ranges[-1][1]==coverage['toBlock']
    assert all(ranges[i][1]+1==ranges[i+1][0] for i in range(len(ranges)-1))
    receipts=json.loads((RAW/'receipt-coverage.json').read_text());assert receipts['requested']==4191 and not receipts['missing']
    for name in ('top100-addresses','top100-wallets'):
        with (ROOT/(name+'.csv')).open(encoding='utf-8-sig',newline='') as f:rows=list(csv.DictReader(f))
        assert len(rows)==100 and len({r['address']for r in rows})==100
        assert all(D(rows[i]['tokens'])>=D(rows[i+1]['tokens']) for i in range(99))
        for r in rows:
            assert D(r['tokens'])*10**18==D(r['raw_balance'])
            if r['remaining_cost_coverage_pct']:
                assert 0<=D(r['remaining_cost_coverage_pct'])<=100+D('1e-40')
                assert abs(D(r['known_remaining_tokens'])+D(r['unknown_remaining_tokens'])-D(r['tokens']))<D('1e-30')
            if r['full_balance_avg_usd']:assert D(r['unknown_remaining_tokens'])<=D('1e-9')
    pdf=ROOT/'STONKEX_Contract_Holder_Analysis_Codex.pdf';reader=PdfReader(pdf)
    assert len(reader.pages)==21 and reader.metadata.author=='Codex'
    for i in range(11,21):assert len(re.findall(r'0x[0-9a-f]{40}',reader.pages[i].extract_text()))==20
    assert all(len(p.extract_text())>300 for p in reader.pages)
    save('report-validation',{'balance_checks':125,'contiguous_ranges':len(ranges),'receipts':receipts['requested'],'csv_rows_each':100,'pdf_pages':21,'pdf_author':'Codex','appendix_full_addresses':200,'pdf_sha256':hashlib.sha256(pdf.read_bytes()).hexdigest(),'result':'passed'})
    print('PASS: 125 balances, continuous logs, 4191 receipts, 2x100 CSV rows, 21-page PDF, 200 complete appendix addresses.')

if __name__=='__main__':main()
