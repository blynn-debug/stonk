import collections,json
from decimal import Decimal as D
from eth_abi import encode,decode
from eth_utils import keccak
from collect import RAW,TOKEN,save
from reconstruct import logs
from scan_logs import TRANSFER,POOL,SWAP
import state

def main():
    first=int(json.loads((RAW/'creation-receipt.json').read_text())['blockNumber'],16);block=json.loads((RAW/'snapshot.json').read_text())['hex'];owner='0x81dd3174d55fcf396e92122881ca591705c4e1e1';outgoing=collections.defaultdict(int);incoming=collections.defaultdict(int);owner_txs=set();firstday_buy=collections.defaultdict(int)
    for l in logs():
        if l['address']!=TOKEN or l['topics'][0]!=TRANSFER:continue
        a='0x'+l['topics'][1][-40:];b='0x'+l['topics'][2][-40:];q=int(l['data'],16)
        if a==owner:outgoing[b]+=q;owner_txs.add(l['transactionHash'])
        if b==owner:incoming[a]+=q;owner_txs.add(l['transactionHash'])
        if int(l['blockNumber'],16)<=first+43200 and a==POOL:firstday_buy[b]+=q
    save('creator-flows',{'owner':owner,'outgoing_raw':{a:str(q) for a,q in sorted(outgoing.items(),key=lambda x:-x[1])},'incoming_raw':{a:str(q) for a,q in sorted(incoming.items(),key=lambda x:-x[1])},'transaction_count':len(owner_txs),'note':'Transfers are not automatically classified as sales; recipients are not assumed to share an owner.'})
    req=[];labels=[]
    slot='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
    for name,address in [('launcher','0x4714f6ec81639ca59eebe634490a4d8671dce7b4'),('locker','0x71d1d363176723f85d98b8b430df33cde89f0a7f')]:
        for when,b in [('launch',hex(first)),('snapshot',block)]:
            labels.append(name+'.implementation.'+when);req.append({'jsonrpc':'2.0','id':len(req),'method':'eth_getStorageAt','params':[address,slot,b]})
    calls=[('lp.owner','0x03a520b32c04bf3beef7beb72e919cf822ed34f1','ownerOf(uint256)',['uint256'],[5872045],['address']),('lp.position','0x03a520b32c04bf3beef7beb72e919cf822ed34f1','positions(uint256)',['uint256'],[5872045],['uint96','address','address','address','uint24','int24','int24','uint128','uint256','uint256','uint128','uint128']),('pool.slot0',POOL,'slot0()',[],[],['uint160','int24','uint16','uint16','uint16','uint8','bool']),('pool.fee',POOL,'fee()',[],[],['uint24']),('pool.wethBalance','0x4200000000000000000000000000000000000006','balanceOf(address)',['address'],[POOL],['uint256'])]
    for label,address,signature,types,args,outs in calls:
        labels.append(label);req.append({'jsonrpc':'2.0','id':len(req),'method':'eth_call','params':[{'to':address,'data':'0x'+keccak(text=signature).hex()[:8]+encode(types,args).hex()},block]})
    state.RPC='https://base.drpc.org';results=state.batch(req,'extra-state-raw')
    decoded={}
    for i,label in enumerate(labels):
        if i not in results:decoded[label]=None;continue
        data=results[i]['result']
        decoded[label]=('0x'+data[-40:]) if i<4 else decode(calls[i-4][-1],bytes.fromhex(data[2:]))
    save('extra-state',decoded);print(decoded,flush=True)

if __name__=='__main__':main()
