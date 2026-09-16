import json,time
from eth_abi import encode,decode
from eth_utils import keccak
from collect import ROOT,RAW,TOKEN,curl,RPC,save
RPC='https://base.drpc.org'

def batch(requests, name):
    pending={q['id']:q for q in requests}; results={}
    for attempt in range(8):
        todo=list(pending.values())
        for start in range(0,len(todo),3):
            group=todo[start:start+3]
            result=curl(RPC,group)
            if isinstance(result,dict):result=[result]
            for r in result:
                if r.get('id') in pending and 'result' in r:
                    results[r['id']]=r;pending.pop(r['id'])
            time.sleep(.2)
        if not pending:break
        time.sleep(min(2**attempt,10))
    save(name,{'rpc':RPC,'requests':requests,'responses':list(results.values()),'failed':list(pending.values())})
    if pending:print(name,'failed',len(pending),flush=True)
    return results

def canonical(item):
    t=item['type']
    return '('+','.join(canonical(c) for c in item['components'])+')'+t[5:] if t.startswith('tuple') else t

def main():
    block=json.loads((RAW/'snapshot.json').read_text())['hex']
    configs=[
        ('token',TOKEN,'STONKEX', ['launcher','creator','totalSupply','decimals','name','symbol']),
        ('launcher','0x4714f6ec81639ca59eebe634490a4d8671dce7b4','implementation-0x6a9f14e7742e8972fcf86429c5aa7db56589806d',['owner','enforcedSupply','feeLocker','quoteRegistry','launchFeeWei']),
        ('locker','0x71d1d363176723f85d98b8b430df33cde89f0a7f','implementation-0x6c9c9fd81b914a59585d966af140211df0325273',['owner','feeRecipient','platformFeeBps','lpFeeBps','burnPlatformCoinShare','pendingFeeSplit','tokenCreator','splitsOf','positionsOf','npm']),
        ('splitter','0xfbc9ee130f1cfeeb192b18cf1202865d757fa680','StonkFeeSplitter',['owner','buyToken','profitReceiver','profitBps','paused','locker']),
        ('index','0x44b5c100513e6f625037c039300c5bc72b73dcbd','implementation-0x439a53ca03b2761ea036173e93cfba3b25ffa339',['owner','creator','mode','coin','quote','factory','creatorShareBps','paused','interval','feeRecipientNow','bindIsPermanent']),
        ('indexFactory','0x78b50dffe7250638d6f2a24f56b0849cefa69498','StockifyIndexFactory',['owner','platformFeeBps','platformFeeRecipient']),
    ]
    requests=[]; specs=[]
    for label,addr,folder,names in configs:
        abi=json.loads((ROOT.parent/'contracts'/folder/'abi.json').read_text())
        for entry in abi:
            if entry.get('type')!='function' or entry['name'] not in names:continue
            ins=[canonical(i) for i in entry['inputs']];args=[TOKEN] if ins==['address'] else []
            signature=entry['name']+'('+','.join(ins)+')'
            data='0x'+keccak(text=signature).hex()[:8]+encode(ins,args).hex()
            ident=len(requests)+1;requests.append({'jsonrpc':'2.0','id':ident,'method':'eth_call','params':[{'to':addr,'data':data},block]})
            specs.append({'id':ident,'contract':label,'address':addr,'function':signature,'outputs':[canonical(i) for i in entry['outputs']]})
    results=batch(requests,'contract-state-raw')
    decoded=[]
    for spec in specs:
        r=results.get(spec['id']); item=dict(spec)
        if r:
            try:item['value']=decode(spec['outputs'],bytes.fromhex(r['result'][2:]))
            except Exception as e:item['error']=type(e).__name__
        else:item['error']='RPC unavailable'
        decoded.append(item)
    save('contract-state',{'block':int(block,16),'values':decoded})
    for item in decoded:print(item['contract'],item['function'],item.get('value',item.get('error')),flush=True)

if __name__=='__main__':main()
