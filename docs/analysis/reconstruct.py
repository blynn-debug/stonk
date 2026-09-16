import collections,json
from decimal import Decimal
from collect import RAW,TOKEN,save
from scan_logs import TRANSFER,SWAP,POOL

def logs():
    for path in sorted((RAW/'logs').glob('*.json')):
        for log in json.loads(path.read_text()):yield log

def main():
    balances=collections.defaultdict(int);counts=collections.Counter();seen=set();transfers=0;swaps=0;negative=0
    for log in logs():
        ident=(log['transactionHash'],log['logIndex'])
        if ident in seen:raise ValueError('Duplicate log')
        seen.add(ident)
        if log['address']==TOKEN and log['topics'][0]==TRANSFER:
            sender='0x'+log['topics'][1][-40:];recipient='0x'+log['topics'][2][-40:];qty=int(log['data'],16)
            balances[sender]-=qty;balances[recipient]+=qty;counts[recipient]+=1;transfers+=1
        elif log['address']==POOL and log['topics'][0]==SWAP:swaps+=1
    zero='0x'+'0'*40;minted=-balances.pop(zero,0)
    assert sum(balances.values())==minted
    assert not any(v<0 for v in balances.values())
    ranked=[{'rank':i,'address':a,'raw_balance':str(b),'tokens':str(Decimal(b)/10**18),'inbound_events':counts[a]} for i,(a,b) in enumerate(sorted(((a,b) for a,b in balances.items() if b>0),key=lambda x:x[1],reverse=True),1)]
    save('all-holders-reconstructed',ranked)
    save('reconstruction-summary',{'logs':len(seen),'transfers':transfers,'swaps':swaps,'positive_holders':len(ranked),'minted_raw':str(minted),'top100_raw':str(sum(int(r['raw_balance']) for r in ranked[:100]))})
    selected={r['address'] for r in ranked[:125]}-{POOL,'0x000000000000000000000000000000000000dead'};groups=collections.defaultdict(list);needed=set()
    for log in logs():
        if log['address']==TOKEN and log['topics'][0]==TRANSFER:
            if '0x'+log['topics'][1][-40:] in selected or '0x'+log['topics'][2][-40:] in selected:needed.add(log['transactionHash'])
    for log in logs():
        if log['transactionHash'] in needed:groups[log['transactionHash']].append(log)
    save('top-holder-transactions',groups)
    print('holders',len(ranked),'transfers',transfers,'swaps',swaps,'selected tx',len(groups),flush=True)
    print('Top10:',[(r['rank'],r['address'],r['tokens']) for r in ranked[:10]],flush=True)

if __name__=='__main__':main()
