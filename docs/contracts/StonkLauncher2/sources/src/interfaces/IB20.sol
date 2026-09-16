// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Minimal local interfaces for the parts of Base's B20 standard this launchpad reads.
 *
 *      B20 tokens (the tokenized-equity "…c" tickers, e.g. NVDAc at
 *      0xb20000000000000000000078ee7ce2fe4908108c) are Rust PRECOMPILES, not EVM contracts:
 *      `eth_getCode` returns the single byte 0xef for a token and EMPTY for the factory, yet every
 *      call dispatches normally. Never gate B20 handling on `code.length`.
 *
 *      Two B20 behaviours matter to a Uniswap V3 launchpad:
 *
 *      1. THE MULTIPLIER IS COSMETIC. ERC-8056 specifies `uiMultiplier` as a value that "rescales the
 *         *displayed* balance without minting, transferring, or rewriting any raw balance", and B20
 *         instructs integrators to "treat raw on-chain amounts as canonical". So `balanceOf`,
 *         `transfer` and `totalSupply` are RAW and NON-REBASING — a stock split moves the multiplier,
 *         never a pool's balance. That is what makes pairing a V3 pool directly against a B20 equity
 *         safe and is why this repo needs no rebasing wrapper. The multiplier is read ONLY to render
 *         share counts in the UI, never in pool math.
 *
 *      2. TRANSFERS ARE POLICY-GATED. Each token maps three scopes (sender / receiver / executor) to a
 *         `uint64` policy id in the PolicyRegistry singleton. On Base mainnet today every equity uses
 *         policy id 5 for all three, which behaves as a BLOCKLIST — arbitrary addresses, including
 *         freshly-created Uniswap pools, are authorized. The issuer could in principle repoint a scope
 *         at an ALLOWLIST, which would freeze trading for any pool not on it. `StonkQuoteRegistry`
 *         exposes these reads so the UI can surface the risk; nothing on the hot path pays for them.
 *
 *      Feature dialling: B20 methods are individually activatable. On mainnet today `multiplier()`
 *      answers while the ERC-8056 alias `uiMultiplier()` REVERTS with the interface id 0xa60bf13d,
 *      and `paused()` reverts with its own selector. Every read here is therefore try/catch'd with a
 *      safe default, never assumed live.
 */

/// @dev The subset of IB20 / IB20Asset this repo calls. All reads are optional-by-design.
interface IB20 {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function totalSupply() external view returns (uint256);

    /// @notice WAD-precision cosmetic scale factor (1e18 == 1.0). Alias of ERC-8056 `uiMultiplier()`.
    ///         Display-only: raw balances are unaffected. See the note above.
    function multiplier() external view returns (uint256);

    /// @notice ERC-8056 spelling of `multiplier()`. Currently NOT activated on Base mainnet.
    function uiMultiplier() external view returns (uint256);

    /// @notice The policy id governing `policyScope` for this token. 0 == ALWAYS_ALLOW.
    function policyId(bytes32 policyScope) external view returns (uint64);

    /// @notice Base64 data-URI carrying `{name, symbol, image}` — the official Coinbase equity icon.
    function contractURI() external view returns (string memory);
}

/// @dev The PolicyRegistry precompile singleton.
interface IPolicyRegistry {
    /// @notice Whether `account` passes `policyId`. Blocklist policies authorize by default.
    function isAuthorized(uint64 policyId, address account) external view returns (bool);
    function policyExists(uint64 policyId) external view returns (bool);
    function policyAdmin(uint64 policyId) external view returns (address);
}

/// @dev The B20 factory precompile. Has NO bytecode but answers calls.
interface IB20Factory {
    function isB20(address account) external view returns (bool);
    function isB20Initialized(address account) external view returns (bool);
}

/// @dev Canonical B20 precompile addresses and policy-scope constants (mirrors base/base-std).
library B20 {
    address internal constant FACTORY = 0xB20f000000000000000000000000000000000000;
    address internal constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;
    address internal constant ACTIVATION_REGISTRY = 0x8453000000000000000000000000000000000001;

    bytes32 internal constant TRANSFER_SENDER_POLICY = keccak256("TRANSFER_SENDER_POLICY");
    bytes32 internal constant TRANSFER_RECEIVER_POLICY = keccak256("TRANSFER_RECEIVER_POLICY");
    bytes32 internal constant TRANSFER_EXECUTOR_POLICY = keccak256("TRANSFER_EXECUTOR_POLICY");

    /// @notice WAD used by the B20 multiplier (1e18 == 1.0).
    uint256 internal constant WAD = 1e18;

    /**
     * @notice Gas allowed to any probe of an untrusted token.
     *
     * @dev NOT paranoia — Base's own WETH needs it. `0x4200…0006` is WETH9, whose fallback runs
     *      `deposit()` and therefore `SSTORE`. Solidity compiles a `view` external call to STATICCALL,
     *      so probing a method WETH does not have is a static-context violation: an EXCEPTIONAL HALT,
     *      which burns the entire 63/64 allotment rather than reverting cheaply. Chain five such
     *      probes — as `quoteView` does — and the caller keeps (1/64)^5 of its gas, which is why
     *      `quoteView(WETH, …)` could not succeed at ANY gas budget before this cap existed.
     */
    uint256 internal constant PROBE_GAS = 100_000;

    /// @dev One bounded, never-reverting read of an untrusted address.
    function _probe(address target, bytes memory data) private view returns (bool ok, bytes32 word) {
        bytes memory ret;
        (ok, ret) = target.staticcall{gas: PROBE_GAS}(data);
        if (!ok || ret.length < 32) return (false, bytes32(0));
        // Take the first word raw. `abi.decode` runs Solidity's strict validator, which reverts on a
        // dirty bool or a uint64 with high bits set — in the CALLER's frame, defeating the point.
        assembly ("memory-safe") {
            word := mload(add(ret, 32))
        }
        ok = true;
    }

    /**
     * @notice Is `token` a B20 precompile token? Genuinely never reverts.
     *
     * @dev A `try/catch` is NOT sufficient here, which is subtle enough to be worth spelling out.
     *      `catch` only runs when the call itself fails. The B20 factory has NO bytecode, so on any
     *      chain or simulator where the precompile is absent the staticcall SUCCEEDS and returns zero
     *      bytes — and the ABI decode of that empty result then reverts in the CALLER's frame, outside
     *      the catch. That turns `addQuote` into a revert on a plain ERC-20 like WETH, which is the
     *      opposite of what this helper claims to do. Checking the returned length is the only way to
     *      express "answer false when the precompile isn't there".
     */
    function isB20(address token) internal view returns (bool) {
        (bool ok, bytes32 word) = _probe(FACTORY, abi.encodeWithSelector(IB20Factory.isB20.selector, token));
        return ok && word != bytes32(0);
    }

    /// @notice The token's cosmetic multiplier, or WAD when the token is not a B20 Asset / the read
    ///         is not activated. DISPLAY ONLY — never feed this into pool or liquidity math.
    function multiplierOr1e18(address token) internal view returns (uint256) {
        // `multiplier()` answers on Base mainnet today while the ERC-8056 alias `uiMultiplier()`
        // reverts — B20 methods are individually activatable — so try both, bounded.
        (bool ok, bytes32 word) = _probe(token, abi.encodeWithSelector(IB20.multiplier.selector));
        if (ok && word != bytes32(0)) return uint256(word);
        (ok, word) = _probe(token, abi.encodeWithSelector(IB20.uiMultiplier.selector));
        if (ok && word != bytes32(0)) return uint256(word);
        return WAD; // a plain ERC-20 has no multiplier at all
    }

    /// @notice `token.totalSupply()`, or 0 when the read is unavailable. Bounded and never reverts.
    function totalSupplyOrZero(address token) internal view returns (uint256) {
        (bool ok, bytes32 word) = _probe(token, abi.encodeWithSelector(IB20.totalSupply.selector));
        return ok ? uint256(word) : 0;
    }

    /// @notice The policy id governing `scope`, or 0 (ALWAYS_ALLOW) when unavailable.
    function policyIdOrZero(address token, bytes32 scope) internal view returns (uint64) {
        (bool ok, bytes32 word) = _probe(token, abi.encodeWithSelector(IB20.policyId.selector, scope));
        // Truncate rather than `abi.decode(…, (uint64))`, whose validator reverts on dirty high bits.
        return ok ? uint64(uint256(word)) : 0;
    }

    /// @notice Would `account` pass `token`'s transfer-receiver policy? True for non-B20 tokens and
    ///         whenever the read is unavailable, so this can never block a plain ERC-20 quote.
    function canReceive(address token, address account) internal view returns (bool) {
        return _passes(token, TRANSFER_RECEIVER_POLICY, account);
    }

    /// @notice Would `account` pass `token`'s transfer-sender policy?
    function canSend(address token, address account) internal view returns (bool) {
        return _passes(token, TRANSFER_SENDER_POLICY, account);
    }

    function _passes(address token, bytes32 scope, address account) private view returns (bool) {
        uint64 pid = policyIdOrZero(token, scope);
        if (pid == 0) return true; // not policy-gated, or ALWAYS_ALLOW

        (bool ok, bytes32 word) = _probe(
            POLICY_REGISTRY, abi.encodeWithSelector(IPolicyRegistry.isAuthorized.selector, pid, account)
        );
        return ok ? word != bytes32(0) : true;
    }
}
