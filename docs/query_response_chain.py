"""Reproduce StatsClient's slot0 read with Base's public default RPC."""
import datetime, json, subprocess
from decimal import Decimal, getcontext
from archive import ROOT, save_json

RPC = 'https://mainnet.base.org'
def rpc(payload):
    result = subprocess.run(['curl.exe','-sS','--max-time','40',RPC,'-H','Content-Type: application/json','--data-binary','@-'],input=json.dumps(payload),capture_output=True,text=True,check=True)
    return json.loads(result.stdout)

def main():
    dest = ROOT / 'response-analysis'
    data = json.loads((dest / 'api/stonkex.json').read_text())
    block_response = rpc({'jsonrpc':'2.0','id':1,'method':'eth_blockNumber','params':[]})
    block = block_response['result']
    reads = [('pool.slot0',data['pool'],'0x3850c7bd'), ('pool.token0',data['pool'],'0x0dfe1681'), ('pool.token1',data['pool'],'0xd21220a7'), ('token.totalSupply',data['token'],'0x18160ddd'), ('token.balanceOf(dead)',data['token'],'0x70a08231'+'000000000000000000000000000000000000000000000000000000000000dead')]
    requests = [{'jsonrpc':'2.0','id':i,'method':'eth_call','params':[{'to':addr,'data':call},block]} for i,(_,addr,call) in enumerate(reads,10)]
    response = rpc(requests)
    save_json(dest / 'chain-reads.json', {'rpc':RPC,'fetched_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'block':int(block,16),'labels':{str(i):name for i,(name,_,_) in enumerate(reads,10)},'requests':requests,'responses':response})
    results = {r['id']:r for r in response}
    if any('error' in r for r in response): raise ValueError('RPC call failed; raw results saved')
    sqrt = int(results[10]['result'][2:66],16)
    scale = 10**30
    ratio = sqrt*sqrt*scale//(2**96)**2
    quote_per_token_scaled = ratio if data['token'].lower()<data['quote'].lower() else scale*scale//ratio
    getcontext().prec = 60
    prices = json.loads((dest/'api/dex-prices.json').read_text())
    quote_usd = Decimal(str(prices['prices'][data['quote'].lower()]['best']['priceUsd']))
    token_usd = Decimal(quote_per_token_scaled)/scale*quote_usd
    supply = int(results[13]['result'],16)
    burned = int(results[14]['result'],16)
    summary = {'block':int(block,16),'sqrtPriceX96':str(sqrt),'token0':'0x'+results[11]['result'][-40:],'token1':'0x'+results[12]['result'][-40:],'totalSupplyTokens':str(Decimal(supply)/10**18),'deadBalanceTokens':str(Decimal(burned)/10**18),'quoteUsdFromApi':str(quote_usd),'tokenUsdFromSlot0':str(token_usd),'marketCapAsStatsClient':str(token_usd*Decimal(data['totalSupply'])/10**18),'note':'Pool state is block-pinned. USD quote and API supply are separate cached snapshots; not all observations share a timestamp.'}
    save_json(dest/'chain-summary.json',summary)
    print(json.dumps(summary,indent=2))

if __name__ == '__main__': main()
