"""Reconstruct STONKEX flows from logs; compute top-100 holders and their average buy price."""
import json, os, bisect, datetime
from collections import defaultdict
from decimal import Decimal, getcontext

getcontext().prec = 50
D = Decimal
HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "0x5ab000ff9b9ffe0349ce5ffa5fd86f217c3680f5"
POOL = "0x7692acc1cdd771d09ebcae3663e1843b2911bec7"
AERO = "0x2b6d89cbb697bc82a0ac961947c610fb1aa77782"
DEAD = "0x000000000000000000000000000000000000dead"
ZERO = "0x0000000000000000000000000000000000000000"
LABELS = {
    DEAD: "dead(소각)", POOL: "Uniswap V3 풀 STONKEX/WETH", AERO: "Aerodrome CL 풀",
    "0x44b5c100513e6f625037c039300c5bc72b73dcbd": "STONKEX 바이백 인덱스",
    "0xfbc9ee130f1cfeeb192b18cf1202865d757fa680": "StonkFeeSplitter",
    "0x71d1d363176723f85d98b8b430df33cde89f0a7f": "StonkFeeLocker2",
    "0x4714f6ec81639ca59eebe634490a4d8671dce7b4": "StonkLauncher2",
    "0x01f178473dcac0ce4b2b2111becfb074b586dd12": "StonkTradeRouter3",
    "0x3e3f3a9f15614fa40244219f025c88602db58e1c": "StonkDisperse",
    "0x81dd3174d55fcf396e92122881ca591705c4e1e1": "creator(런치 지갑)",
}
E18 = D(10) ** 18


def s256(h):
    v = int(h, 16)
    return v - (1 << 256) if v >= (1 << 255) else v


def load():
    meta = json.load(open(os.path.join(HERE, "meta.json")))
    tr = json.load(open(os.path.join(HERE, "transfers.json")))["logs"]
    sw = json.load(open(os.path.join(HERE, "swaps.json")))["logs"]
    aero = json.load(open(os.path.join(HERE, "aero_swaps.json")))["logs"]
    holders = json.load(open(os.path.join(HERE, "holders.json")))
    eth = json.load(open(os.path.join(HERE, "eth_prices.json")))["prices"]
    return meta, tr, sw, aero, holders, eth


def main():
    meta, tr_logs, sw_logs, aero_logs, holders_raw, eth_prices = load()
    start_b, start_ts = meta["start_block"], meta["start_ts"]
    end_b, end_ts = meta["end_block"], meta["end_ts"]
    sec_per_block = (end_ts - start_ts) / (end_b - start_b)
    ts_of = lambda b: start_ts + (b - start_b) * sec_per_block
    eth_t = [p[0] / 1000 for p in eth_prices]
    eth_v = [p[1] for p in eth_prices]

    def eth_usd(ts):
        i = bisect.bisect_left(eth_t, ts)
        if i <= 0: return eth_v[0]
        if i >= len(eth_t): return eth_v[-1]
        t0, t1, v0, v1 = eth_t[i - 1], eth_t[i], eth_v[i - 1], eth_v[i]
        return v0 + (v1 - v0) * (ts - t0) / (t1 - t0)

    # ---- parse logs ----
    transfers = []
    for l in tr_logs:
        transfers.append({"block": int(l["blockNumber"], 16), "tx": l["transactionHash"], "idx": int(l["logIndex"], 16),
                          "from": "0x" + l["topics"][1][-40:], "to": "0x" + l["topics"][2][-40:], "value": int(l["data"], 16)})
    transfers.sort(key=lambda x: (x["block"], x["idx"]))
    swaps = []
    for l in sw_logs:
        d = l["data"][2:]
        words = [d[i:i + 64] for i in range(0, len(d), 64)]
        swaps.append({"block": int(l["blockNumber"], 16), "tx": l["transactionHash"], "idx": int(l["logIndex"], 16),
                      "sender": "0x" + l["topics"][1][-40:], "recipient": "0x" + l["topics"][2][-40:],
                      "amount0": s256(words[0]), "amount1": s256(words[1]), "sqrtP": int(words[2], 16)})
    swaps.sort(key=lambda x: (x["block"], x["idx"]))
    aero_swaps = []
    for l in aero_logs:
        d = l["data"][2:]
        words = [d[i:i + 64] for i in range(0, len(d), 64)]
        aero_swaps.append({"block": int(l["blockNumber"], 16), "tx": l["transactionHash"], "amount0": s256(words[0]), "amount1": s256(words[1])})

    # price series from swaps (WETH per STONKEX): token0=WETH, token1=STONKEX -> price1in0 = 2^192 / sqrtP^2
    price_blocks = [s["block"] for s in swaps]
    price_vals = [D(2 ** 192) / (D(s["sqrtP"]) ** 2) for s in swaps]

    def mkt_price_weth(block):  # last swap price at or before block
        i = bisect.bisect_right(price_blocks, block) - 1
        return price_vals[max(i, 0)]

    # ---- balances by replay ----
    bal = defaultdict(int)
    for t in transfers:
        bal[t["from"]] -= t["value"]; bal[t["to"]] += t["value"]
    del bal[ZERO]
    assert all(v >= 0 for v in bal.values()), "negative balance in replay"

    # ---- group by tx ----
    tx_transfers, tx_swaps = defaultdict(list), defaultdict(list)
    for t in transfers: tx_transfers[t["tx"]].append(t)
    for s in swaps: tx_swaps[s["tx"]].append(s)
    tx_order = sorted(tx_transfers, key=lambda h: (tx_transfers[h][0]["block"], tx_transfers[h][0]["idx"]))

    acct = defaultdict(lambda: {"buy_tok": 0, "buy_weth": D(0), "buy_usd": D(0), "buy_n": 0,
                                "sell_tok": 0, "sell_weth": D(0), "sell_usd": D(0), "sell_n": 0,
                                "in_tok": 0, "in_usd_mkt": D(0), "in_n": 0, "out_tok": 0, "out_n": 0,
                                "first_block": None, "last_block": None, "in_sources": defaultdict(int)})
    stats = {"buy_tx": 0, "sell_tx": 0, "mixed_tx": 0, "plain_tx": 0, "buy_weth": D(0), "sell_weth": D(0),
             "buy_tok": 0, "sell_tok": 0, "unmatched_buy_tok": 0}
    for h in tx_order:
        tl = tx_transfers[h]; sl = tx_swaps.get(h, [])
        block = tl[0]["block"]; ts = ts_of(block); ethp = D(str(eth_usd(ts)))
        net = defaultdict(int)
        for t in tl:
            net[t["from"]] -= t["value"]; net[t["to"]] += t["value"]
        a0 = sum(s["amount0"] for s in sl); a1 = sum(s["amount1"] for s in sl)
        pos = {a: v for a, v in net.items() if v > 0 and a not in (POOL, ZERO)}
        neg = {a: -v for a, v in net.items() if v < 0 and a not in (POOL, ZERO)}
        for a in set(pos) | set(neg):
            r = acct[a]
            r["first_block"] = r["first_block"] or block; r["last_block"] = block
        if sl and a1 < 0 and a0 > 0:  # buy: STONKEX out of pool, WETH in
            stats["buy_tx"] += 1; tok_out = -a1; weth_in = D(a0)
            stats["buy_tok"] += tok_out; stats["buy_weth"] += weth_in
            tot_pos = sum(pos.values())
            if tot_pos == 0:
                stats["unmatched_buy_tok"] += tok_out
            for a, v in pos.items():
                share = D(v) / D(tot_pos)
                r = acct[a]; w = weth_in * share
                # tokens attributed as bought = min(v, tok_out*share) ; excess (from other transfers) = transfer-in
                bought = min(v, int(D(tok_out) * share))
                r["buy_tok"] += bought; r["buy_weth"] += w; r["buy_usd"] += w / E18 * ethp; r["buy_n"] += 1
                if v > bought:
                    r["in_tok"] += v - bought; r["in_n"] += 1
                    r["in_usd_mkt"] += D(v - bought) / E18 * mkt_price_weth(block) * ethp
            for a, v in neg.items():  # someone also sent tokens in this tx (e.g. routing) – count as out
                r = acct[a]; r["out_tok"] += v; r["out_n"] += 1
        elif sl and a1 > 0 and a0 < 0:  # sell
            stats["sell_tx"] += 1; tok_in = a1; weth_out = D(-a0)
            stats["sell_tok"] += tok_in; stats["sell_weth"] += weth_out
            tot_neg = sum(neg.values())
            for a, v in neg.items():
                share = D(v) / D(tot_neg); r = acct[a]; w = weth_out * share
                r["sell_tok"] += v; r["sell_weth"] += w; r["sell_usd"] += w / E18 * ethp; r["sell_n"] += 1
            for a, v in pos.items():
                r = acct[a]; r["in_tok"] += v; r["in_n"] += 1
                r["in_usd_mkt"] += D(v) / E18 * mkt_price_weth(block) * ethp
        else:  # plain transfer / mint / mixed
            if sl: stats["mixed_tx"] += 1
            else: stats["plain_tx"] += 1
            for a, v in pos.items():
                r = acct[a]; r["in_tok"] += v; r["in_n"] += 1
                r["in_usd_mkt"] += D(v) / E18 * mkt_price_weth(block) * ethp if swaps and block >= price_blocks[0] else D(0)
                for t in tl:
                    if t["to"] == a: r["in_sources"][t["from"]] += t["value"]
            for a, v in neg.items():
                r = acct[a]; r["out_tok"] += v; r["out_n"] += 1

    # ---- current price ----
    last = swaps[-1]
    cur_weth = price_vals[-1]
    cur_ethp = D(str(eth_v[-1]))
    cur_usd = cur_weth * cur_ethp
    supply = 10 ** 27

    # ---- holders ----
    bs = {h["address"]["hash"].lower(): h for h in holders_raw["items"]}
    ranked = sorted(bal.items(), key=lambda kv: -kv[1])
    rows = []
    for rank, (a, v) in enumerate(ranked[:100], 1):
        r = acct[a]; h = bs.get(a, {})
        avg_usd = (r["buy_usd"] / (D(r["buy_tok"]) / E18)) if r["buy_tok"] else None
        avg_weth = (r["buy_weth"] / D(r["buy_tok"])) if r["buy_tok"] else None
        tot_acq = r["buy_tok"] + r["in_tok"]
        blended = ((r["buy_usd"] + r["in_usd_mkt"]) / (D(tot_acq) / E18)) if tot_acq else None
        info = h.get("address", {})
        kind = LABELS.get(a) or ("EIP-7702 지갑" if info.get("proxy_type") == "eip7702" else ("컨트랙트" + (f"({info.get('name')})" if info.get("name") else "") if info.get("is_contract") else "EOA"))
        rows.append({
            "rank": rank, "address": a, "label": kind,
            "balance": float(D(v) / E18), "pct_supply": float(D(v) / D(supply) * 100),
            "bs_balance": float(D(h["value"]) / E18) if h else None,
            "buy_tok": float(D(r["buy_tok"]) / E18), "buy_usd": float(r["buy_usd"]), "buy_weth": float(r["buy_weth"] / E18), "buy_n": r["buy_n"],
            "sell_tok": float(D(r["sell_tok"]) / E18), "sell_usd": float(r["sell_usd"]), "sell_n": r["sell_n"],
            "in_tok": float(D(r["in_tok"]) / E18), "in_n": r["in_n"], "out_tok": float(D(r["out_tok"]) / E18),
            "avg_buy_usd": float(avg_usd) if avg_usd is not None else None,
            "avg_buy_weth": float(avg_weth) if avg_weth is not None else None,
            "blended_acq_usd": float(blended) if blended is not None else None,
            "pnl_pct_vs_avg_buy": float((cur_usd - avg_usd) / avg_usd * 100) if avg_usd else None,
            "value_usd_now": float(D(v) / E18 * cur_usd),
            "first_block": r["first_block"], "first_ts": datetime.datetime.fromtimestamp(ts_of(r["first_block"]), datetime.timezone.utc).strftime("%m-%d %H:%M") if r["first_block"] else None,
            "in_sources": {k: float(D(x) / E18) for k, x in sorted(r["in_sources"].items(), key=lambda kv: -kv[1])[:3]},
        })

    # aggregate over "real" holders (exclude dead/pool/aero/contracts of protocol)
    protocol = set(LABELS) - {"0x81dd3174d55fcf396e92122881ca591705c4e1e1"}
    top100_real = [r for r in rows if r["address"] not in protocol]
    agg_buy_tok = sum(r["buy_tok"] for r in top100_real); agg_buy_usd = sum(r["buy_usd"] for r in top100_real)
    all_buy_tok = sum(D(r["buy_tok"]) for r in acct.values()); all_buy_usd = sum(r["buy_usd"] for r in acct.values())
    # holders-wide (everyone with balance>0) cost basis
    hold_buy_tok = sum(D(acct[a]["buy_tok"]) for a, v in bal.items() if v > 0 and a not in protocol)
    hold_buy_usd = sum(acct[a]["buy_usd"] for a, v in bal.items() if v > 0 and a not in protocol)
    n_holders = sum(1 for v in bal.values() if v > 0)
    summary = {
        "as_of_block": end_b, "as_of_utc": datetime.datetime.fromtimestamp(end_ts, datetime.timezone.utc).isoformat(),
        "launch_block": start_b, "launch_utc": datetime.datetime.fromtimestamp(start_ts, datetime.timezone.utc).isoformat(),
        "sec_per_block": sec_per_block, "transfers": len(transfers), "swaps": len(swaps), "aero_swaps": len(aero_swaps),
        "tx": {k: (float(v / E18) if isinstance(v, D) else (float(D(v) / E18) if k.endswith("_tok") else v)) for k, v in stats.items()},
        "holders_replay": n_holders, "holders_blockscout": len(holders_raw["items"]),
        "supply": 1e9, "burned": float(D(bal[DEAD]) / E18), "pool": float(D(bal[POOL]) / E18), "aero_pool": float(D(bal.get(AERO, 0)) / E18),
        "index_holding": float(D(bal.get("0x44b5c100513e6f625037c039300c5bc72b73dcbd", 0)) / E18),
        "top10_pct": sum(r["pct_supply"] for r in rows[:10]), "top100_pct": sum(r["pct_supply"] for r in rows),
        "top10_real_pct": sum(r["pct_supply"] for r in top100_real[:10]), "top100_real_pct": sum(r["pct_supply"] for r in top100_real),
        "cur_price_weth": float(cur_weth), "cur_eth_usd": float(cur_ethp), "cur_price_usd": float(cur_usd), "last_swap_block": last["block"],
        "top100_real_avg_buy_usd": agg_buy_usd / agg_buy_tok if agg_buy_tok else None,
        "top100_real_bought_tok": agg_buy_tok, "top100_real_balance": sum(r["balance"] for r in top100_real),
        "all_buyers_avg_usd": float(all_buy_usd / (all_buy_tok / E18)) if all_buy_tok else None,
        "current_holders_avg_buy_usd": float(hold_buy_usd / (hold_buy_tok / E18)) if hold_buy_tok else None,
        "unique_buyers": sum(1 for r in acct.values() if r["buy_n"]), "unique_sellers": sum(1 for r in acct.values() if r["sell_n"]),
    }
    # price history (daily VWAP from swaps)
    daily = defaultdict(lambda: [D(0), D(0)])
    for s in swaps:
        day = datetime.datetime.fromtimestamp(ts_of(s["block"]), datetime.timezone.utc).strftime("%Y-%m-%d")
        daily[day][0] += D(abs(s["amount0"])); daily[day][1] += D(abs(s["amount1"]))
    summary["daily_vwap_usd"] = {d: float(v[0] / v[1] * D(str(eth_usd(datetime.datetime.strptime(d, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp() + 43200)))) for d, v in sorted(daily.items()) if v[1]}
    # launch-day early buyers
    out = {"summary": summary, "top100": rows}
    json.dump(out, open(os.path.join(HERE, "analysis.json"), "w"), indent=1, ensure_ascii=False)
    print(json.dumps(summary, indent=1, ensure_ascii=False))
    print(f"\n{'#':>3} {'address':42} {'label':14} {'balance':>14} {'%':>6} {'bought':>13} {'avg$':>9} {'pnl%':>7} {'in':>12} {'sold':>12} first")
    for r in rows:
        print(f"{r['rank']:>3} {r['address']:42} {r['label'][:14]:14} {r['balance']:>14,.0f} {r['pct_supply']:>6.2f} {r['buy_tok']:>13,.0f} "
              f"{(r['avg_buy_usd'] if r['avg_buy_usd'] is not None else float('nan')):>9.5f} {(r['pnl_pct_vs_avg_buy'] if r['pnl_pct_vs_avg_buy'] is not None else float('nan')):>7.1f} "
              f"{r['in_tok']:>12,.0f} {r['sell_tok']:>12,.0f} {r['first_ts']}")


if __name__ == "__main__":
    main()
