import json
from collect import RAW,TOKEN,save
from state import batch
import state
state.RPC='https://mainnet.base.org'

def main():
    holders=json.loads((RAW/'all-holders-reconstructed.json').read_text())[:125]
    block=json.loads((RAW/'snapshot.json').read_text())['hex'];req=[]
    for i,h in enumerate(holders):
        req += [{'jsonrpc':'2.0','id':i*2+1,'method':'eth_call','params':[{'to':TOKEN,'data':'0x70a08231'+h['address'][2:].zfill(64)},block]}, {'jsonrpc':'2.0','id':i*2+2,'method':'eth_getCode','params':[h['address'],block]}]
    results=batch(req,'holders-verification-raw')
    for i,h in enumerate(holders):
        b=results.get(i*2+1);c=results.get(i*2+2)
        h['balance_verified']=b is not None and int(b['result'],16)==int(h['raw_balance'])
        h['code']=c['result'] if c else None
        h['account_type']='unknown' if c is None else 'EOA' if c['result']=='0x' else 'delegated_EOA' if c['result'].startswith('0xef0100') else 'contract'
    save('holders-verified',holders)
    print('balances verified',sum(h['balance_verified'] for h in holders),'/',len(holders))
    print('contracts',[(h['rank'],h['address']) for h in holders if h['account_type']=='contract'])

if __name__=='__main__':main()
