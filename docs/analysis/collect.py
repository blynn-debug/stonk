import datetime, json, os, pathlib, subprocess, time, urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent
RAW = ROOT / 'raw'
RAW.mkdir(parents=True, exist_ok=True)
TOKEN = '0x5ab000ff9b9ffe0349ce5ffa5fd86f217c3680f5'
RPC = 'https://mainnet.base.org'

def save(name, data):
    (RAW / (name + '.json')).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')

def curl(url, payload=None):
    args = ['curl.exe','-sS','--max-time','60',url]
    if payload is not None: args += ['-H','Content-Type: application/json','--data-binary','@-']
    p = subprocess.run(args, input=json.dumps(payload) if payload is not None else None, capture_output=True,text=True)
    if p.returncode: raise RuntimeError('HTTP transport failed')
    return json.loads(p.stdout)

def api(name, **params):
    query = dict(chainid=8453, **params)
    url = 'https://api.etherscan.io/v2/api?' + urllib.parse.urlencode(dict(query, apikey=os.environ['ETHERSCAN_API_KEY']))
    result = curl(url)
    save(name, {'query':query,'fetchedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'response':result})
    time.sleep(.55)
    return result

def rpc(method, params):
    for attempt in range(7):
        result = curl(RPC, {'jsonrpc':'2.0','id':1,'method':method,'params':params})
        if 'error' not in result:return result['result']
        time.sleep(min(2**attempt,15))
    raise RuntimeError(str(result['error']))

def probe():
    calls = [
        ('holders',dict(module='token',action='tokenholderlist',contractaddress=TOKEN,page=1,offset=100)),
        ('creation',dict(module='contract',action='getcontractcreation',contractaddresses=TOKEN)),
        ('first_transfers',dict(module='account',action='tokentx',contractaddress=TOKEN,page=1,offset=100,sort='asc')),
    ]
    for name, params in calls:
        result=api(name,**params)
        print(name, result.get('status'), str(result.get('result'))[:700], flush=True)
    block=rpc('eth_blockNumber',[])
    save('snapshot',{'block':int(block,16),'hex':block,'header':rpc('eth_getBlockByNumber',[block,False])})

if __name__ == '__main__': probe()
