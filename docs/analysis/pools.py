import collections,json
from eth_utils import keccak
from collect import RAW,TOKEN,save
import state

V3='0x'+keccak(text='Swap(address,address,int256,int256,uint160,uint128,int24)').hex()
V2='0x'+keccak(text='Swap(address,uint256,uint256,uint256,uint256,address)').hex()
SOLIDLY='0x'+keccak(text='Swap(address,address,uint256,uint256,uint256,uint256)').hex()
V4='0x'+keccak(text='Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)').hex()
INIT='0x'+keccak(text='Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)').hex()
TRANSFER='0x'+keccak(text='Transfer(address,address,uint256)').hex()

def main():
    pairs=collections.Counter();inits={};v4s=collections.Counter()
    for p in (RAW/'receipts').glob('*.json'):
        r=json.loads(p.read_text());counterparties=set()
        for l in r['logs']:
            if l['address']==TOKEN and l['topics'][0]==TRANSFER:
                counterparties.update('0x'+t[-40:] for t in l['topics'][1:])
            if l['topics'][0]==INIT:inits[l['topics'][1]]=l
        for l in r['logs']:
            if l['topics'][0] in (V2,V3,SOLIDLY) and l['address'] in counterparties:pairs[l['address']]+=1
            if l['topics'][0]==V4:v4s[l['topics'][1]]+=1
    block=json.loads((RAW/'snapshot.json').read_text())['hex'];req=[]
    for i,address in enumerate(pairs):
        for j,selector in enumerate(['0x0dfe1681','0xd21220a7']):req.append({'jsonrpc':'2.0','id':i*2+j,'method':'eth_call','params':[{'to':address,'data':selector},block]})
    state.RPC='https://base.drpc.org';result=state.batch(req,'pool-tokens-raw')
    out={}
    for i,address in enumerate(pairs):
        if 2*i in result and 2*i+1 in result:
            t0='0x'+result[2*i]['result'][-40:];t1='0x'+result[2*i+1]['result'][-40:]
            if TOKEN in (t0,t1):out[address]={'token0':t0,'token1':t1,'observed_swaps':pairs[address]}
    v4={pid:{'token0':'0x'+l['topics'][2][-40:],'token1':'0x'+l['topics'][3][-40:],'initialize':l} for pid,l in inits.items() if TOKEN in ['0x'+t[-40:] for t in l['topics'][2:]]}
    save('pool-metadata',{'v2v3':out,'v4':v4,'all_v4_swap_pool_ids':v4s})
    print('token pairs',out,flush=True);print('token v4 pools',list(v4),flush=True)

if __name__=='__main__':main()
