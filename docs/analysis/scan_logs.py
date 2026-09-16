"""Reconstruct balances and swap history from deployment through a pinned block."""
import concurrent.futures, json, time
from collect import RAW, TOKEN, curl, RPC, save

TRANSFER='0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
SWAP='0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67'
POOL='0x7692acc1cdd771d09ebcae3663e1843b2911bec7'

def main():
    first=int(json.loads((RAW/'creation-receipt.json').read_text())['blockNumber'],16)
    last=json.loads((RAW/'snapshot.json').read_text())['block']
    folder=RAW/'logs';folder.mkdir(exist_ok=True)
    def query_range(start,end):
        q={'jsonrpc':'2.0','id':1,'method':'eth_getLogs','params':[{'address':[TOKEN,POOL],'fromBlock':hex(start),'toBlock':hex(end),'topics':[[TRANSFER,SWAP]]}]}
        for attempt in range(9):
            try:
                result=curl(RPC,q)
                if 'result' in result:return result['result']
                if 'too large' in str(result.get('error','')) and start<end:
                    mid=(start+end)//2
                    return query_range(start,mid)+query_range(mid+1,end)
            except (ValueError,RuntimeError):pass
            time.sleep(min(2**attempt,15))
        raise RuntimeError(f'Failed range {start}-{end}: {result.get("error")}')
    def chunk(start):
        end=min(start+1999,last); path=folder/f'{start}-{end}.json'
        if path.exists():return len(json.loads(path.read_text()))
        result=query_range(start,end)
        path.write_text(json.dumps(result),encoding='utf-8');return len(result)
    starts=list(range(first,last+1,2000)); total=0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for i,count in enumerate(pool.map(chunk,starts),1):
            total+=count
            if i%20==0 or i==len(starts):print(f'{i}/{len(starts)} ranges, {total} logs',flush=True)
    save('log-coverage',{'fromBlock':first,'toBlock':last,'ranges':len(starts),'logs':total,'rpc':RPC,'filterAddresses':[TOKEN,POOL],'topic0':[TRANSFER,SWAP]})

if __name__=='__main__':main()
