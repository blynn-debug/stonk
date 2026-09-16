import concurrent.futures,json,time
from collect import RAW,curl,save

RPC='https://mainnet.base.org'

def main():
    txs=list(json.loads((RAW/'investor-transactions.json').read_text()))
    folder=RAW/'receipts';folder.mkdir(exist_ok=True)
    missing=[t for t in txs if not (folder/(t+'.json')).exists()]
    def group_read(group):
        pending={i:t for i,t in enumerate(group)}
        for attempt in range(7):
            req=[{'jsonrpc':'2.0','id':i,'method':'eth_getTransactionReceipt','params':[tx]} for i,tx in pending.items()]
            try:
                result=curl(RPC,req)
                if isinstance(result,dict):result=[result]
                for item in result:
                    if item.get('result') and item.get('id') in pending:
                        tx=pending.pop(item['id']);(folder/(tx+'.json')).write_text(json.dumps(item['result']),encoding='utf-8')
            except Exception:pass
            if not pending:return len(group)
            time.sleep(min(2**attempt,12))
        return len(group)-len(pending)
    groups=[missing[i:i+3] for i in range(0,len(missing),3)]
    print('receipts required',len(txs),'missing',len(missing),flush=True)
    total=0
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for i,n in enumerate(pool.map(group_read,groups),1):
            total+=n
            if i%50==0 or i==len(groups):print('receipts downloaded',total,'/',len(missing),flush=True)
    missing=[t for t in txs if not (folder/(t+'.json')).exists()]
    save('receipt-coverage',{'rpc':RPC,'requested':len(txs),'missing':missing})

if __name__=='__main__':main()
