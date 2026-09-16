import collections,csv,datetime,json
from decimal import Decimal as D,getcontext
from eth_abi import decode
from collect import RAW,ROOT,TOKEN,save
from reconstruct import logs
from scan_logs import TRANSFER,POOL,SWAP
from cost_basis import DEAD,oracle,INFRA

getcontext().prec=60
def main():
    holders=json.loads((RAW/'holder-cost-results.json').read_text());allh=json.loads((RAW/'all-holders-reconstructed.json').read_text());wallets=[r for r in holders if r['role'] in ['EOA','delegated_EOA','smart_wallet']][:100]
    for name,rows in [('top100-addresses',holders[:100]),('top100-wallets',wallets)]:
        with (ROOT/(name+'.csv')).open('w',encoding='utf-8-sig',newline='') as f:
            w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    burns=collections.defaultdict(int);selfs=collections.defaultdict(int);daily=collections.defaultdict(lambda:[D(0),D(0),D(0),0]);ethprice=oracle()
    for l in logs():
        if l['address']==TOKEN and l['topics'][0]==TRANSFER:
            to='0x'+l['topics'][2][-40:];sender='0x'+l['topics'][1][-40:]
            if to==DEAD:burns[sender]+=int(l['data'],16)
            if to==TOKEN:selfs[sender]+=int(l['data'],16)
        elif l['address']==POOL and l['topics'][0]==SWAP:
            words=[l['data'][i:i+64] for i in range(2,len(l['data']),64)];a0=int(words[0],16);a1=int(words[1],16);a0=a0-2**256 if a0>=2**255 else a0;a1=a1-2**256 if a1>=2**255 else a1
            if a0>0 and a1<0:
                block=int(l['blockNumber'],16);p,_=ethprice(block,int(l['logIndex'],16));day=datetime.datetime.fromtimestamp(int(l['blockTimestamp'],16),datetime.timezone.utc).date().isoformat();d=daily[day];d[0]+=D(-a1)/10**18;d[1]+=D(a0)/10**18;d[2]+=D(a0)/10**18*p;d[3]+=1
    summary={'snapshot':json.loads((RAW/'snapshot.json').read_text()),'address_top100_tokens':str(sum(D(r['tokens']) for r in holders[:100])),'address_top10_tokens':str(sum(D(r['tokens']) for r in holders[:10])),'wallet_top100_tokens':str(sum(D(r['tokens']) for r in wallets)),'wallet_top10_tokens':str(sum(D(r['tokens']) for r in wallets[:10])),'wallet_priced_count':sum(r['known_remaining_avg_usd']is not None for r in wallets),'wallet_full_count':sum(r['full_balance_avg_usd']is not None for r in wallets),'wallet_zero_count':sum(D(r['remaining_cost_coverage_pct'])==0 for r in wallets),'wallet_weighted_coverage_pct':str(sum(D(r['known_remaining_tokens'])for r in wallets)/sum(D(r['tokens'])for r in wallets)*100),'wallet_known_cost_usd':str(sum(D(r['estimated_known_remaining_cost_usd'])for r in wallets)),'burn_sources_tokens':{a:str(D(q)/10**18)for a,q in sorted(burns.items(),key=lambda x:-x[1])},'token_self_sources_tokens':{a:str(D(q)/10**18)for a,q in sorted(selfs.items(),key=lambda x:-x[1])},'positive_holders':len(allh),'daily_main_pool_buy_vwap_usd':{day:{'tokens':str(v[0]),'eth':str(v[1]),'usd':str(v[2]),'swaps':v[3],'vwap':str(v[2]/v[0])}for day,v in sorted(daily.items())}}
    extra=json.loads((RAW/'extra-state.json').read_text());oracle_config=json.loads((RAW/'oracle-range.json').read_text());answer=decode(['uint80','int256','uint256','uint256','uint80'],bytes.fromhex(oracle_config['finalLatestRoundData'][2:]))
    summary['eth_usd']=str(D(answer[1])/10**8);summary['spot_price_usd']=str(D(2**192)/D(extra['pool.slot0'][0])**2*D(summary['eth_usd']))
    summary['dead_tokens']=str(sum(D(v)for v in summary['burn_sources_tokens'].values()));summary['self_tokens']=str(sum(D(v)for v in summary['token_self_sources_tokens'].values()))
    save('report-summary',summary)
    print('burn sources',summary['burn_sources_tokens']);print('self sources',len(selfs));print('spot price',summary['spot_price_usd'])

if __name__=='__main__':main()
