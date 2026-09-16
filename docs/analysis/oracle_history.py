import concurrent.futures,json,time
from eth_utils import keccak
from collect import RAW,curl,save

FEED='0x71041dddad3595f9ced3dccfbe3d1f4b0a16bb70'
AGGS=['0x1e0b2c3896338fbb201c4f0a27c6904801dca06b','0x05c84a58fe042275b37db038baacd15f410c7bb0']

def call(signature,block):
    q={'jsonrpc':'2.0','id':1,'method':'eth_call','params':[{'to':FEED,'data':'0x'+keccak(text=signature).hex()[:8]},hex(block)]}
    for attempt in range(6):
        r=curl('https://base.drpc.org',q)
        if 'result'in r:return r['result']
        time.sleep(2+attempt)
    raise RuntimeError(r)

def main():
    first=int(json.loads((RAW/'creation-receipt.json').read_text())['blockNumber'],16)
    last=json.loads((RAW/'snapshot.json').read_text())['block']
    info_path=RAW/'oracle-range.json'
    if not info_path.exists():
        initial=call('latestRoundData()',first)
        final=call('latestRoundData()',last)
        lo,hi=first,last
        while lo+1<hi:
            mid=(lo+hi)//2
            phase=int(call('phaseId()',mid),16)
            if phase==2:lo=mid
            else:hi=mid
            time.sleep(.5)
        save('oracle-range',{'feed':FEED,'aggregators':AGGS,'fromBlock':first,'toBlock':last,'phase3FromBlock':hi,'initialLatestRoundData':initial,'finalLatestRoundData':final})
        print('oracle phase switch',hi,flush=True)
    folder=RAW/'oracle-logs';folder.mkdir(exist_ok=True)
    def scan(start):
        end=min(last,start+1999);path=folder/f'{start}-{end}.json'
        if path.exists():return len(json.loads(path.read_text()))
        q={'jsonrpc':'2.0','id':1,'method':'eth_getLogs','params':[{'address':[FEED]+AGGS,'fromBlock':hex(start),'toBlock':hex(end)}]}
        for attempt in range(8):
            try:
                r=curl('https://mainnet.base.org',q)
                if 'result'in r:
                    path.write_text(json.dumps(r['result']),encoding='utf-8');return len(r['result'])
            except Exception:pass
            time.sleep(min(2**attempt,10))
        raise RuntimeError(f'Oracle logs failed {start}')
    ranges=list(range(first,last+1,2000));total=0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for i,n in enumerate(pool.map(scan,ranges),1):
            total+=n
            if i%80==0 or i==len(ranges):print('oracle ranges',i,'/',len(ranges),'logs',total,flush=True)
    save('oracle-coverage',{'ranges':len(ranges),'logs':total,'fromBlock':first,'toBlock':last})

if __name__=='__main__':main()
