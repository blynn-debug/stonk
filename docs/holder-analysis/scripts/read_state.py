import json, requests
from Crypto.Hash import keccak
C = r"C:/Users/user/PycharmProjects/stonk/docs/contracts"
RPC = "https://base.drpc.org"
STONKEX = "0x5ab000ff9B9FfE0349CE5ffA5fD86f217C3680F5"
def sel(sig): return keccak.new(digest_bits=256, data=sig.encode()).hexdigest()[:8]
def abi_funcs(folder):
    abi = json.load(open(f"{C}/{folder}/abi.json"))
    if isinstance(abi, str): abi = json.loads(abi)
    out = {}
    for f in abi:
        if f.get("type") == "function":
            sig = f["name"] + "(" + ",".join(i["type"] for i in f["inputs"]) + ")"
            out[f["name"]] = (sig, [o["type"] for o in f["outputs"]])
    return out
def call(to, data, block="latest"):
    import time
    for _ in range(6):
        r = requests.post(RPC, json={"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":to,"data":data},block]}, timeout=60).json()
        if r.get("result") is not None: return r["result"]
        if "rate" in json.dumps(r.get("error")).lower(): time.sleep(1.5); continue
        return "ERR " + json.dumps(r.get("error"))
    return "ERR rate limit"
def dec(types, hexres):
    if hexres.startswith("ERR") or hexres == "0x": return hexres
    d = hexres[2:]; w = [d[i:i+64] for i in range(0, len(d), 64)]; out = []
    for i, t in enumerate(types):
        x = w[i]
        if t == "address": out.append("0x" + x[-40:])
        elif t == "bool": out.append(bool(int(x, 16)))
        elif t.startswith("uint") or t.startswith("int"):
            v = int(x, 16); 
            if t.startswith("int") and v >= 1 << 255: v -= 1 << 256
            out.append(v)
        elif t.endswith("[]") or t == "tuple[]" or t == "string":
            off = int(x, 16) // 32; n = int(w[off], 16)
            if t == "string": out.append(bytes.fromhex(d[(off+1)*64:(off+1)*64+n*2]).decode(errors="replace"))
            else: out.append([w[off+1+j] for j in range(min(n*2, len(w)-off-1))])
        else: out.append(x)
    return out
def read(label, folder, addr, names, arg=None):
    funcs = abi_funcs(folder)
    print(f"== {label} {addr}")
    for n in names:
        if n not in funcs: print(f"  {n}: (not in ABI)"); continue
        sig, outs = funcs[n]
        data = "0x" + sel(sig) + (arg[2:].rjust(64, "0") if arg and "(address)" in sig else "")
        print(f"  {n}{'('+arg[:10]+'..)' if arg and '(address)' in sig else ''} -> {dec(outs, call(addr, data))}")
read("StonkFeeLocker2", "implementation-0x6c9c9fd81b914a59585d966af140211df0325273", "0x71D1D363176723f85d98B8B430DF33cde89f0A7f", ["platformFeeBps","lpFeeBps","burnPlatformCoinShare","feeRecipient","owner","pendingFeeSplit"])
read("StonkFeeLocker2 (STONKEX)", "implementation-0x6c9c9fd81b914a59585d966af140211df0325273", "0x71D1D363176723f85d98B8B430DF33cde89f0A7f", ["tokenCreator","tokenQuote","splitsOf","tokenIdOf","positionOf","tokenPosition"], STONKEX)
print("index ABI views:", sorted(n for n,(s,o) in abi_funcs("implementation-0x439a53ca03b2761ea036173e93cfba3b25ffa339").items()))
print("splitter ABI views:", sorted(n for n,(s,o) in abi_funcs("StonkFeeSplitter").items()))
print("factory ABI views:", sorted(n for n,(s,o) in abi_funcs("StockifyIndexFactory").items()))
read("BuybackIndex", "implementation-0x439a53ca03b2761ea036173e93cfba3b25ffa339", "0x44b5c100513e6f625037c039300c5bc72b73dcbd", ["mode","coin","quote","creatorShareBps","interval","paused","keeper","owner","bindIsPermanent","factory","creatorClaimable","totalBurned","totalBought","totalHarvested","bound"])
read("StonkFeeSplitter", "StonkFeeSplitter", "0xfBC9eE130f1CFeeb192b18CF1202865d757FA680", ["buyToken","profitBps","profitReceiver","locker","keeper","owner","paused","veloraTarget"])
read("StonkFeeSplitter retained", "StonkFeeSplitter", "0xfBC9eE130f1CFeeb192b18CF1202865d757FA680", ["retained","valueAsset"], STONKEX)
read("StonkFeeSplitter retained WETH", "StonkFeeSplitter", "0xfBC9eE130f1CFeeb192b18CF1202865d757FA680", ["retained","valueAsset"], "0x4200000000000000000000000000000000000006")
read("StockifyIndexFactory", "StockifyIndexFactory", "0x78b50dFFE7250638D6F2A24f56B0849CefA69498", ["platformFeeBps","platformFeeRecipient","keeper","owner","implementation"])
read("StonkLauncher2", "implementation-0x6a9f14e7742e8972fcf86429c5aa7db56589806d", "0x4714f6EC81639Ca59EEBE634490a4d8671DCe7B4", ["launchFeeWei","feeLocker","quoteRegistry","owner","weth","enforcedSupply","referralSplitter","baseTokenURI"])
read("StonkQuoteRegistry2 (WETH)", "StonkQuoteRegistry2", "0x4db9F13325A83662cf992184bc070755a212e95B", ["isEnabled","launchTickMagnitude","quoteInfo"], "0x4200000000000000000000000000000000000006")
