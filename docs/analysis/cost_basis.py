"""Conservative moving-average DEX execution basis; ordinary transfers remain unpriced."""
import bisect,collections,csv,json
from decimal import Decimal,getcontext
from eth_abi import decode
from eth_utils import keccak
from collect import RAW,ROOT,TOKEN,save
from reconstruct import logs
from pools import V2,V3,V4,SOLIDLY,TRANSFER

getcontext().prec=65
D=Decimal
E18=D(10)**18
ZERO='0x'+'0'*40
WETH='0x4200000000000000000000000000000000000006'
USDC='0x833589fcd6edb6e08f4c7c32d4f71b54bda02913'
DEAD='0x000000000000000000000000000000000000dead'
INFRA={DEAD:'burn_address',TOKEN:'token_self_balance','0x7692acc1cdd771d09ebcae3663e1843b2911bec7':'uniswap_v3_pool','0xba72e99bc76de8d342da78c0e4fc04d605936e71':'amm_pool','0x550b95fcb0e309c552fae9670b1a514d443ca463':'uniswap_v3_pool','0x498581ff718922c3f8e6a244956af099b2652b2b':'uniswap_v4_pool_manager'}

def oracle():
    config=json.loads((RAW/'oracle-range.json').read_text()); initial=decode(['uint80','int256','uint256','uint256','uint80'],bytes.fromhex(config['initialLatestRoundData'][2:]))
    topic='0x'+keccak(text='AnswerUpdated(int256,uint256,uint256)').hex()
    points={a:[] for a in config['aggregators']}
    for path in sorted((RAW/'oracle-logs').glob('*.json')):
        for l in json.loads(path.read_text()):
            if l['topics'][0]==topic and l['address'] in points:
                points[l['address']].append(((int(l['blockNumber'],16),int(l['logIndex'],16)),int(l['topics'][1],16),int(l['data'],16)))
    for a in points:points[a].sort()
    def price(block,logindex=10**9):
        agg=config['aggregators'][0 if block<config['phase3FromBlock'] else 1]
        values=points[agg];i=bisect.bisect_right([p[0] for p in values],(block,logindex))-1
        if i<0:
            if block<config['phase3FromBlock']:return D(initial[1])/10**8,initial[3]
            return None,None
        return D(values[i][1])/10**8,values[i][2]
    return price

def signed(word):
    v=int(word,16);return v-2**256 if v>=2**255 else v

def main():
    price=oracle();metadata=json.loads((RAW/'pool-metadata.json').read_text());holders=json.loads((RAW/'holders-verified.json').read_text());targets={h['address'] for h in holders[:110]}-set(INFRA)
    global_bal=collections.defaultdict(int)
    portfolios={a:dict(known=D(0),usd=D(0),eth=D(0),bought=D(0),buyusd=D(0),buyeth=D(0),unknown_in=D(0),inbound=D(0),buytx=set(),in_tx=set()) for a in targets}
    audit=[];ambiguities=collections.Counter();timestamps={};held_history={}
    def process(group):
        tx=group[0]['transactionHash'];block=int(group[0]['blockNumber'],16)
        base_transfers=[l for l in group if l['address']==TOKEN and l['topics'][0]==TRANSFER]
        relevant=any('0x'+t[-40:] in targets for l in base_transfers for t in l['topics'][1:])
        full=group
        if relevant:
            path=RAW/'receipts'/(tx+'.json')
            if path.exists():full=json.loads(path.read_text())['logs']
            else:ambiguities['missing_receipt']+=1
        transfers=[l for l in full if l['address']==TOKEN and l['topics'][0]==TRANSFER]
        if relevant and len(transfers)!=len(base_transfers):raise ValueError('Receipt/token log coverage mismatch')
        marks={};used=set()
        if relevant:
            swaps=[]
            for l in full:
                topic=l['topics'][0];pair=None;buyq=0;quote_raw=0
                words=[l['data'][i:i+64] for i in range(2,len(l['data']),64)]
                if topic in (V2,V3,SOLIDLY) and l['address'] in metadata['v2v3']:
                    pair=metadata['v2v3'][l['address']];index=0 if pair['token0']==TOKEN else 1
                    if topic==V3:
                        delta=[signed(w) for w in words[:2]];buyq=-delta[index];quote_raw=delta[1-index]
                    else:
                        values=[int(w,16) for w in words[:4]];buyq=values[index+2]-values[index];quote_raw=values[1-index]-values[3-index]
                elif topic==V4 and l['topics'][1] in metadata['v4']:
                    pair=metadata['v4'][l['topics'][1]];index=0 if pair['token0']==TOKEN else 1
                    delta=[signed(w) for w in words[:2]];buyq=delta[index];quote_raw=-delta[1-index]
                if not pair or buyq<=0 or quote_raw<=0:continue
                quote=pair['token1'] if pair['token0']==TOKEN else pair['token0']
                ethusd,updated=price(block,int(l['logIndex'],16))
                if not ethusd:ambiguities['oracle_missing']+=1;continue
                if quote in (ZERO,WETH):eth=D(quote_raw)/E18;usd=eth*ethusd
                elif quote==USDC:usd=D(quote_raw)/10**6;eth=usd/ethusd
                else:ambiguities['unsupported_quote_swap']+=1;continue
                candidates=[t for t in transfers if int(t['logIndex'],16) not in used and '0x'+t['topics'][1][-40:]==l['address'] and int(t['data'],16)==buyq]
                if not candidates:ambiguities['unmatched_swap_output']+=1;continue
                t=min(candidates,key=lambda t:abs(int(t['logIndex'],16)-int(l['logIndex'],16)))
                idx=int(t['logIndex'],16);used.add(idx);marks[idx]=(D(buyq),usd,eth)
        # Only acquisitions generated inside this transaction can carry priced provenance onward.
        # Historical holdings transferred between wallets deliberately carry no assumed purchase basis.
        transient={}
        for l in transfers:
            a='0x'+l['topics'][1][-40:];b='0x'+l['topics'][2][-40:];q=int(l['data'],16);idx=int(l['logIndex'],16)
            if a==b or not q:continue
            before=global_bal[a]
            if a!=ZERO and before<q:raise ValueError(f'Negative inventory {a} {tx}')
            for addr in (a,b):
                if addr not in transient:transient[addr]=[D(global_bal[addr]),D(0),D(0),D(0)]
            ta=transient[a];tb=transient[b]
            ratio=D(q)/ta[0] if ta[0]>0 else D(0)
            carry=[ta[i]*ratio for i in (1,2,3)]
            for i in (1,2,3):ta[i]-=carry[i-1]
            ta[0]-=q
            mark=marks.get(idx)
            if mark is not None:carry=list(mark)
            tb[0]+=q
            for i in (1,2,3):tb[i]+=carry[i-1]
            if a in targets:
                p=portfolios[a];f=D(q)/before if before else D(0)
                for k in ('known','usd','eth'):p[k]*=1-f
            if b in targets:
                p=portfolios[b];known,cusd,ceth=carry
                p['known']+=known;p['usd']+=cusd;p['eth']+=ceth;p['bought']+=known;p['buyusd']+=cusd;p['buyeth']+=ceth;p['unknown_in']+=D(q)-known;p['inbound']+=q;p['in_tx'].add(tx)
                if known>0:p['buytx'].add(tx)
                if relevant:
                    audit.append({'address':b,'tx':tx,'block':block,'log_index':idx,'from':a,'received_tokens':str(D(q)/E18),'priced_tokens':str(known/E18),'execution_cost_usd':str(cusd),'execution_cost_eth':str(ceth),'method':'same_tx_swap_flow_allocation' if known else 'unknown_transfer_or_unpriced_swap'})
            global_bal[a]-=q;global_bal[b]+=q
        timestamps[block]=int(group[0].get('blockTimestamp','0x0'),16)
    group=[];prev=None
    for l in logs():
        tx=l['transactionHash']
        if prev is not None and tx!=prev:process(group);group=[]
        group.append(l);prev=tx
    if group:process(group)
    output=[]
    for h in holders[:110]:
        a=h['address'];assert global_bal[a]==int(h['raw_balance'])
        row={k:v for k,v in h.items() if k not in ('code',)}
        row['role']=INFRA.get(a,'smart_wallet' if h['rank']==6 else h['account_type'])
        if a in portfolios:
            p=portfolios[a];balance=D(h['raw_balance']);known=p['known'];unknown=balance-known
            if abs(unknown)<D('0.000001'):unknown=D(0)
            assert known<=balance+D('0.000001') and known>=0
            row.update(known_remaining_tokens=str(known/E18),unknown_remaining_tokens=str(unknown/E18),remaining_cost_coverage_pct=str(known/balance*100),known_remaining_avg_usd=str(p['usd']/(known/E18)) if known else None,known_remaining_avg_eth=str(p['eth']/(known/E18)) if known else None,full_balance_avg_usd=str(p['usd']/(balance/E18)) if unknown/E18<=D('0.000000001') and known else None,lifetime_priced_buys_tokens=str(p['bought']/E18),lifetime_buy_avg_usd=str(p['buyusd']/(p['bought']/E18)) if p['bought'] else None,lifetime_buy_avg_eth=str(p['buyeth']/(p['bought']/E18)) if p['bought'] else None,priced_buy_transactions=len(p['buytx']),inbound_transactions=len(p['in_tx']),unknown_incoming_tokens=str(p['unknown_in']/E18),estimated_known_remaining_cost_usd=str(p['usd']))
        else:row.update(known_remaining_tokens=None,unknown_remaining_tokens=None,remaining_cost_coverage_pct=None,known_remaining_avg_usd=None,known_remaining_avg_eth=None,full_balance_avg_usd=None,lifetime_priced_buys_tokens=None,lifetime_buy_avg_usd=None,lifetime_buy_avg_eth=None,priced_buy_transactions=None,inbound_transactions=None,unknown_incoming_tokens=None,estimated_known_remaining_cost_usd=None)
        output.append(row)
    save('holder-cost-results',output);save('cost-diagnostics',dict(ambiguities))
    with (ROOT/'acquisition-audit.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(audit[0]));writer.writeheader();writer.writerows(audit)
    print('wallet rows',len(portfolios),'acquisition rows',len(audit),'diagnostics',dict(ambiguities),flush=True)
    print('Top10 costs:',[(r['rank'],r['remaining_cost_coverage_pct'],r['known_remaining_avg_usd']) for r in output[:10]],flush=True)

if __name__=='__main__':main()
