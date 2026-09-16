"""Collect STONKEX on-chain data: Transfer logs, pool Swap logs, holders, ETH prices, launch receipt."""
import json, time, sys, os, datetime
import requests

OUT = os.path.dirname(os.path.abspath(__file__))
TOKEN = "0x5ab000ff9B9FfE0349CE5ffA5fD86f217C3680F5"
POOL = "0x7692AcC1CDd771D09EbCae3663e1843b2911BEC7"
AERO_POOL = "0x2b6D89cBb697BC82a0ac961947C610FB1aA77782"
LAUNCH_TX = "0x03615f1a465b92bbbe75d369b1df35b12758a22af8a5ac5fecb254bb5b13feb6"
START_BLOCK = 50397719
TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
SWAP = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
RPCS = [("https://base.drpc.org", 9999), ("https://mainnet.base.org", 1999)]
S = requests.Session()
S.headers["User-Agent"] = "stonk-analysis/1.0"


def rpc(url, method, params, timeout=90):
    r = S.post(url, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=timeout)
    r.raise_for_status()
    d = r.json()
    if "error" in d:
        raise RuntimeError(d["error"])
    return d["result"]


def latest_block():
    return int(rpc(RPCS[1][0], "eth_blockNumber", []), 16)


def fetch_logs(address, topic0, start, end, cache_name):
    path = os.path.join(OUT, cache_name)
    logs, cur = [], start
    if os.path.exists(path):
        c = json.load(open(path))
        if c["end"] >= end:
            print(f"[{cache_name}] cache hit ({len(c['logs'])} logs)"); return c["logs"]
        logs, cur = c["logs"], c["end"] + 1
    rpc_i = 0
    while cur <= end:
        url, span = RPCS[rpc_i]
        to = min(cur + span - 1, end)
        try:
            res = rpc(url, "eth_getLogs", [{"address": address, "topics": [topic0],
                                            "fromBlock": hex(cur), "toBlock": hex(to)}])
            logs.extend(res)
            cur = to + 1
            if len(logs) % 5000 < len(res):
                print(f"[{cache_name}] up to block {to}: {len(logs)} logs", flush=True)
        except Exception as e:
            print(f"[{cache_name}] {url} error at {cur}-{to}: {str(e)[:120]}", flush=True)
            rpc_i = (rpc_i + 1) % len(RPCS)
            time.sleep(2)
        if len(logs) % 20000 < 100:
            json.dump({"end": cur - 1, "logs": logs}, open(path, "w"))
    json.dump({"end": end, "logs": logs}, open(path, "w"))
    print(f"[{cache_name}] done: {len(logs)} logs", flush=True)
    return logs


def fetch_holders():
    path = os.path.join(OUT, "holders.json")
    items, params = [], {}
    while True:
        r = S.get(f"https://base.blockscout.com/api/v2/tokens/{TOKEN}/holders", params=params, timeout=60)
        r.raise_for_status()
        d = r.json()
        items.extend(d["items"])
        nxt = d.get("next_page_params")
        if not nxt:
            break
        params = nxt
        time.sleep(0.3)
    json.dump({"fetched_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "items": items}, open(path, "w"))
    print(f"[holders] {len(items)} holders", flush=True)
    return items


def fetch_eth_prices():
    path = os.path.join(OUT, "eth_prices.json")
    r = S.get("https://api.coingecko.com/api/v3/coins/ethereum/market_chart",
              params={"vs_currency": "usd", "days": 30}, timeout=60)
    r.raise_for_status()
    d = r.json()
    json.dump(d, open(path, "w"))
    print(f"[eth] {len(d['prices'])} hourly points, first {d['prices'][0]}, last {d['prices'][-1]}", flush=True)


def main():
    end = latest_block()
    print("latest block", end, flush=True)
    meta = {"end_block": end, "fetched_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    # block timestamps for start & end (2s blocks -> interpolation)
    for name, b in [("start", START_BLOCK), ("end", end)]:
        blk = rpc(RPCS[1][0], "eth_getBlockByNumber", [hex(b), False])
        meta[f"{name}_block"] = b; meta[f"{name}_ts"] = int(blk["timestamp"], 16)
    # immutables
    for name, sel in [("launcher", "0x16eebd1e"), ("creator", "0x02d05d3f")]:
        res = rpc(RPCS[1][0], "eth_call", [{"to": TOKEN, "data": sel}, "latest"])
        meta[name] = "0x" + res[-40:]
    # launch receipt
    meta["launch_receipt"] = rpc(RPCS[1][0], "eth_getTransactionReceipt", [LAUNCH_TX])
    meta["launch_tx"] = rpc(RPCS[1][0], "eth_getTransactionByHash", [LAUNCH_TX])
    json.dump(meta, open(os.path.join(OUT, "meta.json"), "w"), indent=1)
    print("meta saved", {k: v for k, v in meta.items() if not k.startswith("launch_")}, flush=True)
    fetch_eth_prices()
    fetch_holders()
    fetch_logs(TOKEN, TRANSFER, START_BLOCK, end, "transfers.json")
    fetch_logs(POOL, SWAP, START_BLOCK, end, "swaps.json")
    fetch_logs(AERO_POOL, SWAP, START_BLOCK, end, "aero_swaps.json")
    print("ALL DONE", flush=True)


if __name__ == "__main__":
    main()
