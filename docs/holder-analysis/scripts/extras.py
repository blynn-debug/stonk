import json, bisect, datetime, requests, time
from collections import defaultdict, Counter
from decimal import Decimal as D
E=D(10)**18
meta=json.load(open("meta.json")); tr=json.load(open("transfers.json"))["logs"]; sw=json.load(open("swaps.json"))["logs"]
eth=json.load(open("eth_prices.json"))["prices"]; et=[p[0]/1000 for p in eth]; ev=[p[1] for p in eth]
sb,st=meta["start_block"],meta["start_ts"]; ts=lambda b: st+(b-sb)*2
def ethusd(t):
    i=bisect.bisect_left(et,t); i=min(max(i,1),len(et)-1); return ev[i-1]+(ev[i]-ev[i-1])*(t-et[i-1])/(et[i]-et[i-1])
def s256(h):
    v=int(h,16); return v-(1<<256) if v>=(1<<255) else v
T=[{"b":int(l["blockNumber"],16),"tx":l["transactionHash"],"i":int(l["logIndex"],16),"f":"0x"+l["topics"][1][-40:],"t":"0x"+l["topics"][2][-40:],"v":int(l["data"],16)} for l in tr]
T.sort(key=lambda x:(x["b"],x["i"]))
S=[]
for l in sw:
    d=l["data"][2:]; w=[d[i:i+64] for i in range(0,len(d),64)]
    S.append({"b":int(l["blockNumber"],16),"tx":l["transactionHash"],"a0":s256(w[0]),"a1":s256(w[1]),"sq":int(w[2],16)})
S.sort(key=lambda x:x["b"])
POOL="0x7692acc1cdd771d09ebcae3663e1843b2911bec7"; CR="0x81dd3174d55fcf396e92122881ca591705c4e1e1"; DEAD="0x000000000000000000000000000000000000dead"
IDX="0x44b5c100513e6f625037c039300c5bc72b73dcbd"; SPL="0xfbc9ee130f1cfeeb192b18cf1202865d757fa680"; LOCK="0x71d1d363176723f85d98b8b430df33cde89f0a7f"; LAUNCH="0x4714f6ec81639ca59eebe634490a4d8671dce7b4"
out={}
# 1. launch-window: first 300 blocks (10 min) buys
sw_tx=defaultdict(list)
for s in S: sw_tx[s["tx"]].append(s)
def window(n_blocks):
    buys=defaultdict(lambda:[0,D(0)]); n=0
    for s in S:
        if s["b"]>sb+n_blocks: break
        if s["a1"]<0: n+=1
    return n
tx_first=defaultdict(list)
for t in T: tx_first[t["tx"]].append(t)
# per-tx buyer attribution (same as analyze): net positive receivers excluding pool
def buyers_in(tx):
    net=defaultdict(int)
    for t in tx_first[tx]: net[t["f"]]-=t["v"]; net[t["t"]]+=t["v"]
    return {a:v for a,v in net.items() if v>0 and a!=POOL and int(a,16)!=0}
cohorts={}
for name,nb in [("block0-1 (0-2s)",1),("first 10 blocks (20s)",10),("first 30 blocks (1min)",30),("first 300 blocks (10min)",300),("first 1800 blocks (1h)",1800),("first day",43200)]:
    tok=0; weth=D(0); buyers=set(); ntx=0
    for tx,ss in sw_tx.items():
        b=ss[0]["b"]
        if b>sb+nb: continue
        a0=sum(s["a0"] for s in ss); a1=sum(s["a1"] for s in ss)
        if a1<0 and a0>0:
            ntx+=1; tok+=-a1; weth+=D(a0); buyers|=set(buyers_in(tx))
    cohorts[name]={"buy_tx":ntx,"buyers":len(buyers),"tokens":float(D(tok)/E),"pct_supply":float(D(tok)/E/D(1e7)),"weth":float(weth/E),"avg_price_usd":float(weth/D(tok)*D(str(ethusd(ts(sb+nb//2))))) if tok else None}
out["launch_cohorts"]=cohorts
# holdings still held by first-10-block buyers
bal=defaultdict(int)
for t in T: bal[t["f"]]-=t["v"]; bal[t["t"]]+=t["v"]
early=set()
for tx,ss in sw_tx.items():
    if ss[0]["b"]<=sb+10 and sum(s["a1"] for s in ss)<0: early|=set(buyers_in(tx))
out["first10_buyers_now_hold"]={"n":len(early),"tokens_now":float(sum(D(bal[a]) for a in early)/E),"n_still_holding_gt_1M":sum(1 for a in early if bal[a]>1e24)}
out["first10_buyer_list"]=sorted([(a,float(D(bal[a])/E)) for a in early],key=lambda x:-x[1])[:15]
# 2. creator wallet flows
cr_in=defaultdict(int); cr_out=defaultdict(int); cr_tx=defaultdict(lambda:[0,0])
for t in T:
    if t["t"]==CR: cr_in[t["f"]]+=t["v"]
    if t["f"]==CR: cr_out[t["t"]]+=t["v"]; cr_tx[t["tx"]][0]+=1; cr_tx[t["tx"]][1]+=t["v"]
out["creator"]={"balance_now":float(D(bal[CR])/E),"in_total":float(sum(cr_in.values())/E),"out_total":float(sum(cr_out.values())/E),
 "in_by_source":{k:float(D(v)/E) for k,v in sorted(cr_in.items(),key=lambda kv:-kv[1])[:8]},
 "out_by_dest_top":{k:float(D(v)/E) for k,v in sorted(cr_out.items(),key=lambda kv:-kv[1])[:8]},
 "out_recipients":len(cr_out),"out_tx":len(cr_tx),
 "disperse_like_txs":[(tx,n,float(D(v)/E)) for tx,(n,v) in sorted(cr_tx.items(),key=lambda kv:-kv[1][0])[:6]]}
# 3. burn paths
dead_src=defaultdict(int)
for t in T:
    if t["t"]==DEAD: dead_src[t["f"]]+=t["v"]
out["burn_by_source"]={k:float(D(v)/E) for k,v in sorted(dead_src.items(),key=lambda kv:-kv[1])}
# index & splitter flows
def flows(a):
    i=defaultdict(int); o=defaultdict(int)
    for t in T:
        if t["t"]==a: i[t["f"]]+=t["v"]
        if t["f"]==a: o[t["t"]]+=t["v"]
    return {"in":{k:float(D(v)/E) for k,v in sorted(i.items(),key=lambda kv:-kv[1])[:5]},"out":{k:float(D(v)/E) for k,v in sorted(o.items(),key=lambda kv:-kv[1])[:5]},"bal":float(D(bal[a])/E)}
out["index_flows"]=flows(IDX); out["splitter_flows"]=flows(SPL); out["locker_flows"]=flows(LOCK); out["launcher_flows"]=flows(LAUNCH)
out["token_contract_self"]=flows("0x5ab000ff9b9ffe0349ce5ffa5fd86f217c3680f5")
# index buy cost (WETH spent by index buys)
idx_w=D(0); idx_t=0
for tx,ss in sw_tx.items():
    bs=buyers_in(tx)
    if IDX in bs or SPL in bs:
        a0=sum(s["a0"] for s in ss); a1=sum(s["a1"] for s in ss)
        if a1<0: idx_w+=D(a0); idx_t+=-a1
out["buyback_swaps"]={"weth_spent":float(idx_w/E),"tokens_bought":float(D(idx_t)/E)}
# 4. distribution buckets (excluding protocol/pool/dead)
prot={POOL,DEAD,IDX,SPL,LOCK,LAUNCH,"0x5ab000ff9b9ffe0349ce5ffa5fd86f217c3680f5","0x2b6d89cbb697bc82a0ac961947c610fb1aa77782","0x550b95fcb0e309c552fae9670b1a514d443ca463","0x498581ff718922c3f8e6a244956af099b2652b2b"}
hold=[(a,v) for a,v in bal.items() if v>0 and a not in prot]
buckets=[(">=10M",1e25),(">=1M",1e24),(">=100k",1e23),(">=10k",1e22),(">=1k",1e21),(">0",1)]
bk={}; prev=None
for name,th in buckets:
    xs=[v for a,v in hold if v>=th and (prev is None or v<prev)]
    bk[name]={"holders":len(xs),"tokens":float(sum(xs)/E),"pct":float(sum(xs)/E/D(1e7))}; prev=th
out["buckets"]=bk; out["holders_total_gt0"]=len(hold)+len([a for a in prot if bal[a]>0])
out["holders_gt_1usd_equiv"]=sum(1 for a,v in hold if v>=137e18)
# 5. other pool 0x550b tokens
def call(to,data):
    for _ in range(5):
        r=requests.post("https://base.drpc.org",json={"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":to,"data":data},"latest"]},timeout=60).json()
        if "result" in r: return r["result"]
        time.sleep(1.5)
p="0x550b95fcb0e309c552fae9670b1a514d443ca463"
out["pool_550b"]={"token0":"0x"+call(p,"0x0dfe1681")[-40:],"token1":"0x"+call(p,"0xd21220a7")[-40:],"fee":int(call(p,"0xddca3f43"),16),"stonkex_bal":float(D(bal[p])/E)}
# 6. price path: launch price, ATH (daily max of swap price), current
prices=[(s["b"], float(D(2**192)/D(s["sq"])**2)*ethusd(ts(s["b"]))) for s in S[::20]]
mx=max(prices,key=lambda x:x[1]); out["price"]={"launch_first_swap_usd":prices[0][1],"ath_usd":mx[1],"ath_time":datetime.datetime.fromtimestamp(ts(mx[0]),datetime.timezone.utc).isoformat(),"current_usd":prices[-1][1]}
# 7. volume totals
out["volume"]={"buy_weth":float(sum(D(s["a0"]) for s in S if s["a0"]>0)/E),"sell_weth":float(-sum(D(s["a0"]) for s in S if s["a0"]<0)/E)}
json.dump(out,open("extras.json","w"),indent=1,ensure_ascii=False)
print(json.dumps(out,indent=1,ensure_ascii=False))
