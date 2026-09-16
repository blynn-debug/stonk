// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IB20, B20} from "./interfaces/IB20.sol";
import {TickMath08} from "./lib/TickMath08.sol";

/// @dev Chainlink's aggregator surface, declared locally rather than imported: four signatures do
///      not justify a dependency. Always point at the EACAggregatorProxy, never the aggregator
///      behind it — the proxy is the stable address across Chainlink's phase migrations, and on
///      Base the proxies are unrestricted while the aggregators themselves gate reads.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title StonkQuoteRegistry2
 * @notice V2 of the quote registry: the set of assets a coin may be launched AGAINST, each carrying
 *         an owner-set ANCHOR tick magnitude plus, optionally, a Chainlink feed that keeps that
 *         anchor honest as the quote's market price moves.
 *
 * @dev WHY AN ANCHOR PLUS A FEED, RATHER THAN THE FEED ALONE. V1 stored a hand-computed tick per
 *      quote; it was exact on deploy day and drifted every day after. Reading the feed as the sole
 *      source of truth would fix the drift but import three failure modes wholesale: equity feeds
 *      pause for entire weekends (53h observed on Coinbase NVDA), the feeds themselves are weeks
 *      old, and a feed that starts reverting would brick every launch against its quote — under a
 *      launcher whose logic is frozen forever. So the stored anchor REMAINS the value the launcher
 *      reads, and the feed CORRECTS it:
 *
 *        - `sync(quote)` — called by the V2 launcher inside every launch, and permissionless for
 *          anyone else — derives the magnitude that would put a fresh launch at `targetMcapUsd`
 *          from the feed's current answer, and rewrites the anchor ONLY when the two disagree by
 *          at least `deadbandTicks`. Within the band the anchor holds still, so the UI's preview
 *          and the landed launch agree except when the market genuinely moved.
 *        - `sync` NEVER reverts: a stale answer, a broken feed, a paused market, an absurd derived
 *          value — every failure leaves the anchor as it was and lets the launch proceed. Pricing
 *          degrades to V1 behaviour; it never becomes an outage.
 *
 *      The launcher-facing surface (`isEnabled`, `launchTickMagnitude`) is byte-compatible with V1,
 *      as are the frontend views, so the UI's registry bindings carry over unchanged.
 *
 * @dev Magnitudes are stored POSITIVE; the launcher applies the sign from token ordering and aligns
 *      down to the 1% tier's 200-tick spacing (see StonkLauncher2._band). The derivation here
 *      produces the UNALIGNED magnitude — alignment is the launcher's job, exactly as in V1.
 */
contract StonkQuoteRegistry2 is Ownable {
    struct Quote {
        bool enabled;
        uint8 decimals;
        int24 launchTickMagnitude;
        bool isB20;
        string symbol;
    }

    struct Feed {
        /// @notice Chainlink EACAggregatorProxy for this quote's USD price. 0 = no feed: the quote
        ///         is anchor-only and behaves exactly like a V1 entry.
        address aggregator;
        /// @notice Oldest answer `sync` will act on. Per quote because heartbeats genuinely differ:
        ///         crypto feeds tick around the clock; an equity feed sleeps through the weekend.
        uint32 maxAgeSeconds;
    }

    /// @notice quote token => configuration. Struct shape identical to V1 so UI decoders carry over.
    mapping(address => Quote) public quotes;

    /// @notice quote token => oracle wiring. Kept out of `Quote` so the V1 getter ABI is preserved.
    mapping(address => Feed) public feedOf;

    /// @notice Every quote ever added, enabled or not (append-only; disable rather than remove).
    address[] public quoteList;

    /// @notice The opening market cap every launch targets, in whole dollars. ONE number for all
    ///         quotes — cross-quote comparability is the entire point of a fixed opening cap.
    uint256 public targetMcapUsd = 4_000;

    /// @notice Minimum disagreement, in ticks, between the feed-derived magnitude and the stored
    ///         anchor before `sync` rewrites the anchor. 400 ticks ~= 4%, two spacings: below it a
    ///         resync would not even move the aligned launch tick reliably, and the anchor holding
    ///         still keeps UI previews honest between signing and inclusion.
    int24 public deadbandTicks = 400;

    /// @notice The fixed launch supply the magnitude derivation assumes (1e9 coins, 18 decimals).
    ///         Matches the launcher's enforced supply; if that constant were ever changed, this
    ///         registry's derivation — and every anchor — must be revisited together with it.
    uint256 public constant PRICING_SUPPLY = 1e27;

    /// @notice The 1% fee tier's tick spacing — the granularity the launcher aligns to.
    int24 internal constant TICK_SPACING = 200;

    /// @notice Gas ceiling for each probe into the feed. A real EACAggregatorProxy read costs
    ///         ~25k; the cap only exists so a hostile or broken feed burns a bounded amount of the
    ///         LAUNCH's gas rather than all of it — try/catch alone cannot bound that.
    uint256 internal constant FEED_PROBE_GAS = 200_000;

    event QuoteAdded(address indexed token, string symbol, uint8 decimals, bool isB20, int24 tickMagnitude);
    event QuoteEnabledSet(address indexed token, bool enabled);
    event LaunchTickMagnitudeSet(address indexed token, int24 tickMagnitude);
    event FeedSet(address indexed token, address indexed aggregator, uint32 maxAgeSeconds);
    event AnchorSynced(address indexed token, int24 oldMagnitude, int24 newMagnitude, uint256 priceUsd1e18);
    event TargetMcapUsdSet(uint256 usd);
    event DeadbandTicksSet(int24 ticks);

    error AlreadyAdded();
    error UnknownQuote();
    error BadTickMagnitude();
    error DecimalsTooLarge();
    error LengthMismatch();
    error BadTarget();
    error BadDeadband();

    constructor(address owner_) Ownable(owner_) {}

    // ------------------------------------------------------------------ admin

    /**
     * @notice Register a quote asset with its opening anchor and, optionally, its Chainlink feed.
     * @param token          The quote asset (a B20 equity, or WETH).
     * @param tickMagnitude  Positive tick distance from parity pinning the opening price — the
     *                       anchor `sync` will keep current when a feed is configured.
     * @param aggregator     Chainlink proxy for the token's USD price, or 0 for anchor-only mode.
     * @param maxAgeSeconds  Staleness tolerance for that feed (ignored when aggregator is 0).
     */
    function addQuote(address token, int24 tickMagnitude, address aggregator, uint32 maxAgeSeconds)
        external
        onlyOwner
    {
        if (_isListed(token)) revert AlreadyAdded();
        _requireValidMagnitude(tickMagnitude);

        uint8 dec = IB20(token).decimals();
        if (dec > 18) revert DecimalsTooLarge();

        string memory sym;
        try IB20(token).symbol() returns (string memory s) {
            sym = s;
        } catch {
            sym = "";
        }
        bool b20 = B20.isB20(token);

        quotes[token] =
            Quote({enabled: true, decimals: dec, launchTickMagnitude: tickMagnitude, isB20: b20, symbol: sym});
        quoteList.push(token);
        emit QuoteAdded(token, sym, dec, b20, tickMagnitude);

        if (aggregator != address(0)) {
            feedOf[token] = Feed({aggregator: aggregator, maxAgeSeconds: maxAgeSeconds});
            emit FeedSet(token, aggregator, maxAgeSeconds);
        }
    }

    /// @notice Point a quote at a (new) feed, or detach it (aggregator = 0 → anchor-only mode).
    function setFeed(address token, address aggregator, uint32 maxAgeSeconds) external onlyOwner {
        if (!_isListed(token)) revert UnknownQuote();
        feedOf[token] = Feed({aggregator: aggregator, maxAgeSeconds: maxAgeSeconds});
        emit FeedSet(token, aggregator, maxAgeSeconds);
    }

    /// @notice Enable or disable a quote for NEW launches. Never touches existing pools.
    function setQuoteEnabled(address token, bool enabled) external onlyOwner {
        if (!_isListed(token)) revert UnknownQuote();
        quotes[token].enabled = enabled;
        emit QuoteEnabledSet(token, enabled);
    }

    /// @notice Manually retune one quote's anchor. Still here with feeds configured: it is the
    ///         recovery path when a feed misbehaves and the escape hatch for feedless quotes.
    function setLaunchTickMagnitude(address token, int24 tickMagnitude) external onlyOwner {
        if (!_isListed(token)) revert UnknownQuote();
        _requireValidMagnitude(tickMagnitude);
        quotes[token].launchTickMagnitude = tickMagnitude;
        emit LaunchTickMagnitudeSet(token, tickMagnitude);
    }

    /// @notice Batch form of the manual retune.
    function setLaunchTickMagnitudes(address[] calldata tokens, int24[] calldata tickMagnitudes)
        external
        onlyOwner
    {
        if (tokens.length != tickMagnitudes.length) revert LengthMismatch();
        for (uint256 i; i < tokens.length; i++) {
            if (!_isListed(tokens[i])) revert UnknownQuote();
            _requireValidMagnitude(tickMagnitudes[i]);
            quotes[tokens[i]].launchTickMagnitude = tickMagnitudes[i];
            emit LaunchTickMagnitudeSet(tokens[i], tickMagnitudes[i]);
        }
    }

    /// @notice Retune the opening market cap every future launch targets. Applies uniformly — there
    ///         is deliberately no per-quote or per-launch override.
    function setTargetMcapUsd(uint256 usd) external onlyOwner {
        // Below $100 the derived ticks push into dust; above $1M the "fair open" story is gone.
        if (usd < 100 || usd > 1_000_000) revert BadTarget();
        targetMcapUsd = usd;
        emit TargetMcapUsdSet(usd);
    }

    /// @notice Retune the sync deadband. 0 = every fresh read rewrites the anchor.
    function setDeadbandTicks(int24 ticks) external onlyOwner {
        // A band wider than ~20k ticks (~7.4x price) would let the anchor drift absurdly far.
        if (ticks < 0 || ticks > 20_000) revert BadDeadband();
        deadbandTicks = ticks;
        emit DeadbandTicksSet(ticks);
    }

    /// @dev Renouncing is disabled. The owner is the only address that can list new equities,
    ///      repair a broken feed binding, or retune anchors for feedless quotes.
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }

    // ------------------------------------------------------------------ sync

    /**
     * @notice Refresh `token`'s anchor from its feed, if the feed is fresh and disagrees by at
     *         least the deadband. Permissionless, and called by the V2 launcher inside every
     *         launch, so the anchor tracks the market exactly when tracking matters.
     *
     * @dev NEVER reverts by design. Every failure mode — unlisted token, no feed, revert inside
     *      the aggregator, stale/incomplete/non-positive answer, a derived magnitude outside the
     *      launchable band — leaves the anchor untouched and returns. This function sits on the
     *      launch hot path of a launcher whose logic can never be patched; "worse pricing" must
     *      never escalate into "no launches".
     */
    function sync(address token) external {
        if (!_isListed(token)) return;
        (bool ok, int24 derived, uint256 px) = _derive(token);
        if (!ok) return;

        int24 anchor = quotes[token].launchTickMagnitude;
        int24 diff = derived > anchor ? derived - anchor : anchor - derived;
        if (diff < deadbandTicks) return;

        quotes[token].launchTickMagnitude = derived;
        emit AnchorSynced(token, anchor, derived, px);
    }

    /// @notice What `sync` would do right now — for the UI's launch preview and for ops.
    /// @return fresh        The feed answered, in tolerance, with a usable derived magnitude.
    /// @return derived      The magnitude the feed implies (0 when not fresh).
    /// @return anchor       The currently stored magnitude.
    /// @return wouldUpdate  Whether `sync` would rewrite the anchor.
    /// @return priceUsd1e18 The feed's answer scaled to 1e18 (0 when not fresh).
    function previewSync(address token)
        external
        view
        returns (bool fresh, int24 derived, int24 anchor, bool wouldUpdate, uint256 priceUsd1e18)
    {
        anchor = quotes[token].launchTickMagnitude;
        if (!_isListed(token)) return (false, 0, anchor, false, 0);
        (fresh, derived, priceUsd1e18) = _derive(token);
        if (!fresh) return (false, 0, anchor, false, 0);
        int24 diff = derived > anchor ? derived - anchor : anchor - derived;
        wouldUpdate = diff >= deadbandTicks;
    }

    /**
     * @dev Feed answer -> the tick magnitude that opens a `PRICING_SUPPLY` launch at
     *      `targetMcapUsd`. Unit chain, kept explicit because each step has been wrong somewhere:
     *
     *        usdPerRawCoin(1e18-scaled)  = targetMcapUsd * 1e18 / PRICING_SUPPLY
     *        rawQuotePerRawCoin (P)      = usdPerRawCoin * 10^quoteDecimals / priceUsd1e18
     *        sqrtPriceX96                = sqrt(P * 2^192)
     *        tick                        = largest t with getSqrtRatioAtTick(t) <= sqrtPriceX96
     *        magnitude                   = -tick   (P < 1 in every sane configuration)
     *
     *      The tick inversion is a ~21-step binary search over the SAME audited
     *      `TickMath08.getSqrtRatioAtTick` the launcher prices with, rather than a ported log2
     *      routine — one source of truth for tick math, at ~15k gas on the rare syncs that run it.
     */
    function _derive(address token) internal view returns (bool ok, int24 magnitude, uint256 priceUsd1e18) {
        Feed memory f = feedOf[token];
        if (f.aggregator == address(0)) return (false, 0, 0);

        int256 answer;
        uint256 updatedAt;
        {
            uint80 roundId;
            uint80 answeredInRound;
            // Gas-capped: try/catch swallows a REVERT but not gas already burned before it, so an
            // owner-set feed that spins instead of reverting would otherwise starve the launch
            // call around this sync (audit V2 L-01). Same discipline as `B20.PROBE_GAS`.
            try IAggregatorV3(f.aggregator).latestRoundData{gas: FEED_PROBE_GAS}() returns (
                uint80 rid, int256 ans, uint256, uint256 upd, uint80 air
            ) {
                (roundId, answer, updatedAt, answeredInRound) = (rid, ans, upd, air);
            } catch {
                return (false, 0, 0);
            }
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return (false, 0, 0);
            if (block.timestamp - updatedAt > f.maxAgeSeconds) return (false, 0, 0);
            if (answeredInRound < roundId) return (false, 0, 0);
        }

        uint8 feedDec;
        try IAggregatorV3(f.aggregator).decimals{gas: FEED_PROBE_GAS}() returns (uint8 d) {
            feedDec = d;
        } catch {
            return (false, 0, 0);
        }
        if (feedDec > 38) return (false, 0, 0);
        if (feedDec <= 18) {
            // Checked scaling: an unchecked multiply here overflowed — and therefore REVERTED —
            // for answers >= ~1.16e67 on an 8-decimal feed, breaking this function's never-revert
            // contract on the launch hot path (audit V2 M-01). An answer that large is garbage by
            // definition, so it is treated as "not fresh", never as an error.
            uint256 scale = 10 ** (18 - feedDec);
            if (uint256(answer) > type(uint256).max / scale) return (false, 0, 0);
            priceUsd1e18 = uint256(answer) * scale;
        } else {
            priceUsd1e18 = uint256(answer) / 10 ** (feedDec - 18);
        }
        if (priceUsd1e18 == 0) return (false, 0, 0);

        // ratioQ96 = targetMcapUsd * 1e18 * 10^qdec * 2^96 / (PRICING_SUPPLY * priceUsd1e18),
        // in two 512-bit mulDivs so no intermediate truncates or overflows.
        uint256 ratioQ96 = Math.mulDiv(targetMcapUsd * 1e18, 1 << 96, PRICING_SUPPLY);
        ratioQ96 = Math.mulDiv(ratioQ96, 10 ** quotes[token].decimals, priceUsd1e18);
        // Guard the shift below; also rejects a ratio at/above parity, which no sane config produces.
        if (ratioQ96 == 0 || ratioQ96 >= 1 << 160) return (false, 0, 0);

        uint160 sqrtP = uint160(Math.sqrt(ratioQ96 << 96));
        // P must sit strictly below parity (tick < 0) and above the most negative usable tick.
        if (sqrtP >= TickMath08.getSqrtRatioAtTick(0)) return (false, 0, 0);
        if (sqrtP < TickMath08.getSqrtRatioAtTick(TickMath08.MIN_TICK)) return (false, 0, 0);

        int24 tick = _tickAtOrBelow(sqrtP);
        int24 mag = -tick;
        int24 maxUsable = (TickMath08.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        if (mag < TICK_SPACING || mag >= maxUsable) return (false, 0, 0);

        return (true, mag, priceUsd1e18);
    }

    /// @dev Largest tick whose sqrt ratio does not exceed `sqrtP`, by binary search over the
    ///      audited forward function. Caller guarantees sqrtP ∈ [ratio(MIN_TICK), ratio(0)).
    function _tickAtOrBelow(uint160 sqrtP) internal pure returns (int24) {
        int256 lo = TickMath08.MIN_TICK;
        int256 hi = 0;
        while (lo < hi) {
            int256 mid = (lo + hi + 1) / 2; // ceil, so progress is guaranteed when hi = mid - 1
            if (TickMath08.getSqrtRatioAtTick(int24(mid)) <= sqrtP) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return int24(lo);
    }

    // ------------------------------------------------------------------ views used by the launcher

    /// @notice Is this asset accepted for new launches?
    function isEnabled(address token) external view returns (bool) {
        return quotes[token].enabled;
    }

    /// @notice The opening tick magnitude for `token` — the anchor, which `sync` keeps current.
    ///         Reverts for an unregistered quote so a launch can never silently open at parity.
    function launchTickMagnitude(address token) external view returns (int24) {
        if (!_isListed(token)) revert UnknownQuote();
        return quotes[token].launchTickMagnitude;
    }

    function decimalsOf(address token) external view returns (uint8) {
        return quotes[token].decimals;
    }

    function quoteCount() external view returns (uint256) {
        return quoteList.length;
    }

    function allQuotes() external view returns (address[] memory) {
        return quoteList;
    }

    // ------------------------------------------------------------------ views used by the frontend

    /// @notice Everything the UI needs about one quote in a single call. Identical to V1.
    function quoteView(address token, address probe)
        external
        view
        returns (
            Quote memory info,
            uint256 multiplier,
            uint256 totalSupply,
            bool receiverOk,
            bool senderOk,
            uint64 receiverPolicyId
        )
    {
        info = quotes[token];
        multiplier = B20.multiplierOr1e18(token);
        totalSupply = B20.totalSupplyOrZero(token);
        receiverOk = B20.canReceive(token, probe);
        senderOk = B20.canSend(token, probe);
        receiverPolicyId = B20.policyIdOrZero(token, B20.TRANSFER_RECEIVER_POLICY);
    }

    /// @notice Cosmetic multiplier for `token` (1e18 when absent). DISPLAY ONLY.
    function multiplierOf(address token) external view returns (uint256) {
        return B20.multiplierOr1e18(token);
    }

    /// @notice Whether `account` may currently RECEIVE `token` under its B20 policy.
    function canReceive(address token, address account) external view returns (bool) {
        return B20.canReceive(token, account);
    }

    /// @notice Whether `account` may currently SEND `token` under its B20 policy.
    function canSend(address token, address account) external view returns (bool) {
        return B20.canSend(token, account);
    }

    // ------------------------------------------------------------------ internals

    function _requireValidMagnitude(int24 magnitude) private pure {
        // Anything under one full spacing aligns to 0 in the launcher (revert), anything at or
        // above the launcher's aligned maximum is equally unlaunchable — same bounds as V1.
        int24 maxUsable = (TickMath08.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        if (magnitude < TICK_SPACING || magnitude >= maxUsable) revert BadTickMagnitude();
    }

    /// @dev Listing marker: a magnitude is validated non-zero on every write, so non-zero means —
    ///      and only ever means — "this quote has been added".
    function _isListed(address token) private view returns (bool) {
        return quotes[token].launchTickMagnitude != 0;
    }
}
