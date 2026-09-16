// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {INPM} from "./interfaces/IV3.sol";

interface IStonkLauncherBaseURI {
    function baseTokenURI() external view returns (string memory);
}

/**
 * @title StonkFeeLocker2
 * @notice Rug-proof holder of the Uniswap V3 LP position NFT for every Stonks Exchange launch.
 *
 * @dev V2 DELTAS — this file is StonkFeeLocker (live at 0xEb64…450C, audited) with exactly two
 *      changes, both closing findings from that audit:
 *        1. M-02: `setFeeSplit` was instant and retroactive on accrued-but-uncollected fees. It is
 *           now a propose/execute pair behind the same 24h delay + 7d grace window that already
 *           governs creator transfers, so a split change is ANNOUNCED on-chain a day before it can
 *           touch anyone's stream.
 *        2. L-02: `onERC721Received` accepted any NFT the position manager delivered, so a
 *           mis-sent third-party LP NFT was irrecoverably swallowed. It now rejects transfers
 *           outright (see the function for why this cannot affect launch registration).
 *      Everything else — every value path, every guarantee — is byte-identical to V1 on purpose:
 *      the diff IS the audit surface.
 *
 * @dev SECURITY MODEL — the liquidity PRINCIPAL is locked FOREVER:
 *      This contract holds each launch's position NFT and can only ever:
 *        1. `collect()` the accrued V3 swap fees, and
 *        2. split those fees between the platform, the position's creator, and (when `lpFeeBps` is
 *           non-zero) an auto-liquidity share COMPOUNDED BACK into the same position.
 *
 *      `increaseLiquidity` is purely ADDITIVE — it can only grow a position, never shrink it. There
 *      is deliberately NO code path that calls `decreaseLiquidity`, `burn`, NFT `transferFrom` /
 *      `safeTransferFrom`, or NFT `approve` / `setApprovalForAll`. So no one — owner, creator, or
 *      anyone else — can ever withdraw the underlying liquidity or the NFT. A reviewer can confirm
 *      by grepping: the only INPM selectors that touch a position are `collect` (fees) and
 *      `increaseLiquidity` (compound), plus `positions`/`ownerOf` (view).
 *
 *      The owner's ONLY powers are: change the fee split bps (hard-capped, creator always keeps
 *      >=20%, and timelocked — see `proposeFeeSplit`), set `feeRecipient`, reassign a coin's creator
 *      (community takeovers, timelocked), and toggle the platform coin-share burn. None can touch
 *      the NFTs or principal, and upgrades revert unconditionally.
 *
 * @dev PER-POSITION QUOTE. The ETH-paired ancestor of this contract identified a position's project
 *      side by comparing against one global WETH address. Here every launch may use a DIFFERENT
 *      quote — any B20 equity, or WETH — so the quote is recorded per position at `register` time and
 *      read back from storage. That is exact rather than inferred, and it keeps the platform's payout
 *      rule ("the quote side is always paid out, never burned") correct across every pairing.
 *
 * FEE SPLIT (of collected swap fees, in bps of 10000): `lpFeeBps` compounded back into liquidity,
 * `platformFeeBps` to `feeRecipient`, and the REMAINDER to the position's creator. Deployed config is
 * 0 / 3000 / 7000  ==>  no auto-liquidity, 0.3% platform, 0.7% creator per 1% trade.
 *
 * @dev Those percentages are of what the POOL PAYS OUT, which is not automatically the whole 1%.
 *      Uniswap's factory owner can switch on a protocol fee per pool via `setFeeProtocol`, and
 *      already runs 1/6 on Base's canonical 1% pools. New pools start at 0, but if it were ever
 *      enabled on a Stonks pool the real split becomes ~0.583% creator / 0.250% platform. Nothing
 *      here can prevent that, so it should not be advertised as guaranteed.
 */
contract StonkFeeLocker2 is OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, IERC721Receiver {
    using SafeERC20 for IERC20;

    /// @notice Hard caps: platform <= 30%, LP <= 60%, and platform+LP <= 80% (creator keeps >=20%).
    uint256 public constant MAX_PLATFORM_FEE_BPS = 3000;
    uint256 public constant MAX_LP_FEE_BPS = 6000;
    uint256 public constant MAX_TAKEN_BPS = 8000;
    /// @notice Standard burn sink for the platform's coin-token fee share (when burning is enabled).
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice How long a creator transfer must sit announced on-chain before it can be applied.
    uint256 public constant CREATOR_TRANSFER_DELAY = 24 hours;
    /// @notice How long after the delay a proposal stays executable. Without a window an owner could
    ///         pre-arm a takeover for every coin on day one and fire it silently a year later, which
    ///         would turn the announcement into no notice at all.
    uint256 public constant CREATOR_TRANSFER_GRACE = 7 days;
    /// @notice Delay + grace for fee-split changes — the same announcement discipline as creator
    ///         transfers, because both reroute someone's future money.
    uint256 public constant FEE_SPLIT_DELAY = 24 hours;
    uint256 public constant FEE_SPLIT_GRACE = 7 days;

    INPM public npm;

    /// @notice The launcher factory allowed to register newly-minted positions.
    address public launcher;

    /// @notice Platform's share of collected swap fees, in bps.
    uint256 public platformFeeBps;
    /// @notice Share compounded back into the position (auto-liquidity), in bps.
    uint256 public lpFeeBps;
    /// @notice Recipient of the platform's fee share.
    address public feeRecipient;

    struct Position {
        address creator;
        bool active;
        /// @notice The asset this position's coin trades against (a B20 equity, or WETH). Recorded at
        ///         registration; the OTHER side of the pool is the launched coin.
        address quote;
    }

    /// @notice tokenId => position record.
    mapping(uint256 => Position) public positionsInfo;
    /// @notice project token => its position NFT ids.
    mapping(address => uint256[]) public tokenPositions;
    /// @notice project token => its creator (the wallet that launched it). Controls the fee split.
    mapping(address => address) public tokenCreator;
    /// @notice project token => the quote asset it was launched against.
    mapping(address => address) public tokenQuote;

    struct Split {
        address to;
        uint256 bps;
    }

    /// @notice project token => creator's fee-split recipients (bps sum to 10000). Empty = all to creator.
    mapping(address => Split[]) internal creatorSplits;

    /// @notice When true, the platform's COIN-TOKEN fee share is burned (→ DEAD) instead of paid to
    ///         `feeRecipient`. The QUOTE side is never burned — it is a real equity or real ETH.
    bool public burnPlatformCoinShare;

    /// @notice A creator transfer that has been announced but not yet applied.
    struct PendingCreator {
        address newCreator;
        uint64 executeAfter;
    }

    /// @notice project token => the pending creator transfer, if any.
    mapping(address => PendingCreator) public pendingTokenCreator;

    /// @notice A fee-split change that has been announced but not yet applied.
    struct PendingFeeSplit {
        uint16 platformBps;
        uint16 lpBps;
        uint64 executeAfter; // 0 = nothing pending
    }

    /// @notice The pending fee-split change, if any.
    PendingFeeSplit public pendingFeeSplit;

    /// @notice payee => token => amount owed because a direct payout could not be delivered.
    mapping(address => mapping(address => uint256)) public claimable;

    event LauncherSet(address indexed launcher);
    event PositionRegistered(uint256 indexed tokenId, address indexed creator, address indexed quote);
    event FeeSplitSet(uint256 platformBps, uint256 lpBps);
    event FeeSplitProposed(uint256 platformBps, uint256 lpBps, uint64 executeAfter);
    event FeeSplitCancelled(uint256 platformBps, uint256 lpBps);
    event FeeRecipientSet(address indexed recipient);
    event FeesCollected(
        uint256 indexed tokenId,
        address indexed creator,
        address token0,
        address token1,
        uint256 lp0,
        uint256 lp1,
        uint256 platform0,
        uint256 platform1,
        uint256 creator0,
        uint256 creator1
    );
    event CreatorSplitSet(address indexed token, address indexed by, uint256 recipients);
    event TokenCreatorSet(address indexed token, address indexed from, address indexed to);
    event TokenCreatorProposed(
        address indexed token, address indexed from, address indexed to, uint64 executeAfter
    );
    event TokenCreatorTransferCancelled(address indexed token, address indexed cancelled);
    event BurnPlatformCoinShareSet(bool enabled);
    event PayoutDeferred(address indexed to, address indexed token, uint256 amount);
    event PayoutClaimed(address indexed to, address indexed token, uint256 amount);

    /// @dev Upgrades are permanently disabled by design — see _authorizeUpgrade.
    error UpgradesFrozen();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address npm_,
        address owner_,
        address feeRecipient_,
        uint256 platformFeeBps_,
        uint256 lpFeeBps_
    ) external initializer {
        require(npm_ != address(0), "npm=0");
        require(feeRecipient_ != address(0), "feeRecipient=0");
        require(platformFeeBps_ <= MAX_PLATFORM_FEE_BPS && lpFeeBps_ <= MAX_LP_FEE_BPS, "bps>max");
        require(platformFeeBps_ + lpFeeBps_ <= MAX_TAKEN_BPS, "taken>max");
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        npm = INPM(npm_);
        feeRecipient = feeRecipient_;
        platformFeeBps = platformFeeBps_;
        lpFeeBps = lpFeeBps_;
    }

    // ------------------------------------------------------------------ wiring

    /// @notice One-time set of the authorized launcher (owner only).
    function setLauncher(address launcher_) external onlyOwner {
        require(launcher == address(0), "launcher set");
        require(launcher_ != address(0), "launcher=0");
        launcher = launcher_;
        emit LauncherSet(launcher_);
    }

    /// @notice Register a freshly-minted position, recording its creator and quote asset. Only the
    ///         launcher may call. `quote` MUST be one of the position's two tokens — checked here so
    ///         a mis-wired launcher can never register a position whose project side would be
    ///         misidentified, which would misroute every future fee payout.
    /**
     * @param feeRecipient_ Where the creator's fee stream should be paid. Pass `address(0)` (or the
     *        creator) to pay the launching wallet, which is the default.
     *
     * @dev A recipient set here is recorded as the creator's SPLIT, not as the creator. The
     *      distinction matters: `creator` is who may later re-route the stream via
     *      `setCreatorSplit`, while the split is merely where it currently lands. Writing the
     *      recipient into `creator` instead would hand control to a wallet that may well be a cold
     *      address or a multisig that never intends to call anything — and the launching wallet
     *      would silently lose the ability to change its mind.
     */
    function register(uint256 tokenId, address creator, address quote, address feeRecipient_) external {
        require(msg.sender == launcher, "not launcher");
        require(creator != address(0), "creator=0");
        require(quote != address(0), "quote=0");
        require(positionsInfo[tokenId].creator == address(0), "registered");
        require(npm.ownerOf(tokenId) == address(this), "not held");

        (,, address t0, address t1,,,,,,,,) = npm.positions(tokenId);
        require(quote == t0 || quote == t1, "quote not in pool");

        positionsInfo[tokenId] = Position({creator: creator, active: true, quote: quote});
        address proj = _index(tokenId, t0, t1, quote);

        if (feeRecipient_ != address(0) && feeRecipient_ != creator && creatorSplits[proj].length == 0) {
            creatorSplits[proj].push(Split(feeRecipient_, 10000));
            emit CreatorSplitSet(proj, creator, 1);
        }

        emit PositionRegistered(tokenId, creator, quote);
    }

    // -------------------------------------------------- fee collection (the only value-moving action)

    /// @notice Collect + split the accrued swap fees for one position. Permissionless (funds can only
    ///         flow to the creator, the platform, or back into liquidity), so anyone may crank it.
    function collectFees(uint256 tokenId) external nonReentrant {
        _collect(tokenId);
    }

    /// @notice Collect + split fees for ALL of a token's positions in one call.
    function collectAll(address token) external nonReentrant {
        uint256[] memory ids = tokenPositions[token];
        require(ids.length > 0, "no positions");
        for (uint256 i; i < ids.length; i++) {
            _collect(ids[i]);
        }
    }

    /// @dev The six per-collect fee amounts. Held in ONE memory struct rather than six stack slots:
    ///      `_collect` juggles the position record, both pool tokens and both collected totals on top
    ///      of these, which overflows the EVM's 16-slot reachable stack window.
    struct FeeSplit {
        uint256 lp0;
        uint256 lp1;
        uint256 pl0;
        uint256 pl1;
        uint256 c0;
        uint256 c1;
    }

    function _collect(uint256 tokenId) internal {
        Position memory p = positionsInfo[tokenId];
        require(p.active, "unknown position");
        (,, address token0, address token1,,,,,,,,) = npm.positions(tokenId);

        (uint256 a0, uint256 a1) = npm.collect(
            INPM.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        if (a0 == 0 && a1 == 0) return;

        FeeSplit memory f;
        (f.lp0, f.pl0, f.c0) = _split3(a0);
        (f.lp1, f.pl1, f.c1) = _split3(a1);

        _compound(tokenId, token0, token1, f);
        _payPlatform(p.quote, token0, token1, f);
        _payCreator(token0, token1, token0 == p.quote ? token1 : token0, p.creator, f.c0, f.c1);

        emit FeesCollected(
            tokenId, p.creator, token0, token1, f.lp0, f.lp1, f.pl0, f.pl1, f.c0, f.c1
        );
    }

    /// @dev Auto-liquidity: compound the LP share back into THIS position (additive; can't unwind).
    ///      A single-sided fee only compounds when the position sits single-sided at the current tick
    ///      (an out-of-range band). If the position is in-range, adding one token with 0 of the other
    ///      reverts — so we try/catch and, on failure, route that share to the creator instead. Thus
    ///      collectAll never reverts and no funds are stranded.
    function _compound(uint256 tokenId, address token0, address token1, FeeSplit memory f) internal {
        if (f.lp0 == 0 && f.lp1 == 0) return;

        if (f.lp0 > 0) IERC20(token0).forceApprove(address(npm), f.lp0);
        if (f.lp1 > 0) IERC20(token1).forceApprove(address(npm), f.lp1);
        try npm.increaseLiquidity(
            INPM.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: f.lp0,
                amount1Desired: f.lp1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        ) returns (uint128, uint256 used0, uint256 used1) {
            f.c0 += f.lp0 - used0; // unused (out-of-range side) -> creator
            f.c1 += f.lp1 - used1;
        } catch {
            f.c0 += f.lp0; // couldn't compound (in-range, single-sided) -> creator
            f.c1 += f.lp1;
        }
        if (f.lp0 > 0) IERC20(token0).forceApprove(address(npm), 0);
        if (f.lp1 > 0) IERC20(token1).forceApprove(address(npm), 0);
    }

    /// @dev The QUOTE side (a real equity, or real ETH) always goes to `feeRecipient`. The coin side
    ///      goes there too, UNLESS `burnPlatformCoinShare` is on — then it is sent to DEAD, a
    ///      deflationary sink on the platform's cut. The quote side is never burned.
    function _payPlatform(address quote, address token0, address token1, FeeSplit memory f) internal {
        bool quoteIs0 = token0 == quote;
        uint256 plQuote = quoteIs0 ? f.pl0 : f.pl1;
        uint256 plCoin = quoteIs0 ? f.pl1 : f.pl0;
        address coinTok = quoteIs0 ? token1 : token0;
        _pay(quote, feeRecipient, plQuote);
        _pay(coinTok, burnPlatformCoinShare ? DEAD : feeRecipient, plCoin);
    }

    /**
     * @dev Pay `to`, or record the debt if the transfer will not go through.
     *
     *      WHY THIS CANNOT SIMPLY `safeTransfer`. A B20 equity is policy-gated, and the issuer may
     *      repoint a transfer scope at an allowlist at any time. If a single payee — the platform's
     *      `feeRecipient`, or one of up to twenty creator-split recipients — stops being authorized,
     *      an atomic payout would revert the ENTIRE collect. That would strand the coin-side fees too,
     *      even though the coin is an ungoverned ERC-20 that transfers perfectly well, and there is no
     *      rescue path anywhere in this contract. One blocked address must not freeze everyone's money.
     *
     *      A deferred amount is claimable later, so nothing is lost if the block is temporary.
     */
    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;

        // Deliberately assembly, mirroring OpenZeppelin's `SafeERC20._callOptionalReturnBool`.
        // `abi.decode(ret, (bool))` is NOT total — it reverts on returndata of 1..31 bytes and on a
        // non-canonical boolean word — and that revert would propagate out of a function whose entire
        // contract is "never revert", taking the whole collect down with it. The `extcodesize` check
        // covers the other direction: a call to a codeless address succeeds with empty returndata and
        // would otherwise be booked as a delivered payment that never happened.
        bool delivered;
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, to, amount);
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            delivered :=
                and(
                    success,
                    or(
                        and(iszero(returndatasize()), gt(extcodesize(token), 0)),
                        and(gt(returndatasize(), 31), eq(mload(0), 1))
                    )
                )
        }
        if (delivered) return;

        claimable[to][token] += amount;
        emit PayoutDeferred(to, token, amount);
    }

    /// @notice Withdraw fees that could not be delivered when they were collected.
    function claim(address token) external nonReentrant {
        uint256 amount = claimable[msg.sender][token];
        require(amount > 0, "nothing to claim");
        claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit PayoutClaimed(msg.sender, token, amount);
    }

    /// @dev Split an amount into (lp, platform, creator). Creator gets the remainder.
    function _split3(uint256 amount) internal view returns (uint256 lp, uint256 platform, uint256 creator) {
        lp = (amount * lpFeeBps) / 10000;
        platform = (amount * platformFeeBps) / 10000;
        creator = amount - lp - platform;
    }

    /// @dev Record project token -> position ids (dedup). Project = whichever side is not the quote.
    function _index(uint256 tokenId, address t0, address t1, address quote) internal returns (address proj) {
        proj = t0 == quote ? t1 : t0;
        if (tokenCreator[proj] == address(0)) tokenCreator[proj] = positionsInfo[tokenId].creator;
        if (tokenQuote[proj] == address(0)) tokenQuote[proj] = quote;
        uint256[] storage arr = tokenPositions[proj];
        for (uint256 i; i < arr.length; i++) {
            if (arr[i] == tokenId) return proj;
        }
        arr.push(tokenId);
    }

    /// @notice The position ids indexed for a token.
    function positionsOf(address token) external view returns (uint256[] memory) {
        return tokenPositions[token];
    }

    /// @notice The quote asset recorded for a position.
    function quoteOf(uint256 tokenId) external view returns (address) {
        return positionsInfo[tokenId].quote;
    }

    // --------------------------------------------------------- owner controls (params only, never NFTs)

    /**
     * @notice Owner-only, TIMELOCKED: announce a fee-split change. V1's `setFeeSplit` was instant,
     *         which meant the owner could cut every creator's share — including on fees already
     *         accrued but not yet collected, since the split is applied at `_collect` time — in one
     *         unannounced transaction (audit finding M-02). The caps were never the problem; the
     *         silence was. A day of notice lets any creator collect under the split they signed up
     *         for before a new one can land.
     *
     * @dev Re-proposing overwrites and restarts the clock, mirroring `proposeTokenCreator`.
     */
    function proposeFeeSplit(uint256 platformBps, uint256 lpBps) external onlyOwner {
        require(platformBps <= MAX_PLATFORM_FEE_BPS && lpBps <= MAX_LP_FEE_BPS, "bps>max");
        require(platformBps + lpBps <= MAX_TAKEN_BPS, "taken>max");
        uint64 executeAfter = uint64(block.timestamp + FEE_SPLIT_DELAY);
        pendingFeeSplit =
            PendingFeeSplit({platformBps: uint16(platformBps), lpBps: uint16(lpBps), executeAfter: executeAfter});
        emit FeeSplitProposed(platformBps, lpBps, executeAfter);
    }

    /// @notice Apply an announced fee-split change once its delay has elapsed, within the grace
    ///         window. The caps were validated at proposal time and cannot change in between.
    function executeFeeSplit() external onlyOwner {
        PendingFeeSplit memory p = pendingFeeSplit;
        require(p.executeAfter != 0, "no pending split");
        require(block.timestamp >= p.executeAfter, "timelocked");
        require(block.timestamp <= p.executeAfter + FEE_SPLIT_GRACE, "proposal expired");

        delete pendingFeeSplit;
        platformFeeBps = p.platformBps;
        lpFeeBps = p.lpBps;
        emit FeeSplitSet(p.platformBps, p.lpBps);
    }

    /// @notice Abandon a pending fee-split change.
    function cancelFeeSplit() external onlyOwner {
        PendingFeeSplit memory p = pendingFeeSplit;
        require(p.executeAfter != 0, "no pending split");
        delete pendingFeeSplit;
        emit FeeSplitCancelled(p.platformBps, p.lpBps);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "recipient=0");
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /**
     * @notice Owner-only, TIMELOCKED: begin handing a coin's creator role — and with it the creator
     *         fee stream — to a new wallet. For community takeovers of coins whose devs have gone.
     *
     * @dev WHY THIS ONE WAITS. It names a specific coin and moves that coin's entire fee stream to a
     *      different wallet, so it is the owner action most likely to be contested by the person it
     *      affects. The delay does not remove the power — a takeover has to stay possible for
     *      abandoned coins — it makes the power ANNOUNCED, on-chain, a full day before it can land.
     *
     *      It is not the only owner power that touches creator earnings — the fee split is the
     *      other — but as of V2 both wait behind the same 24-hour announcement (see
     *      `proposeFeeSplit`): this delay protects a creator's IDENTITY on a coin, that one the
     *      SIZE of every creator's cut.
     *
     *      Re-proposing overwrites a pending transfer and restarts the clock, so the delay can never
     *      be shortened by queueing a different destination.
     */
    function proposeTokenCreator(address token, address newCreator) external onlyOwner {
        require(newCreator != address(0), "creator=0");
        address old = tokenCreator[token];
        require(old != address(0), "unknown token");
        require(newCreator != old, "same creator");

        uint64 executeAfter = uint64(block.timestamp + CREATOR_TRANSFER_DELAY);
        pendingTokenCreator[token] = PendingCreator({newCreator: newCreator, executeAfter: executeAfter});
        emit TokenCreatorProposed(token, old, newCreator, executeAfter);
    }

    /// @notice Owner-only: abandon a pending creator transfer.
    function cancelTokenCreator(address token) external onlyOwner {
        PendingCreator memory p = pendingTokenCreator[token];
        require(p.newCreator != address(0), "no pending transfer");
        delete pendingTokenCreator[token];
        emit TokenCreatorTransferCancelled(token, p.newCreator);
    }

    /**
     * @notice Owner-only: finalize a creator transfer once its 24-hour delay has elapsed.
     *
     * @dev The old creator loses the stream completely: the role moves, every position's recorded
     *      creator moves with it, and the old creator's configured split is cleared so fees cannot
     *      keep paying wallets they chose. Only the NEW creator can route it from here.
     */
    function executeTokenCreator(address token) external onlyOwner {
        PendingCreator memory p = pendingTokenCreator[token];
        require(p.newCreator != address(0), "no pending transfer");
        require(block.timestamp >= p.executeAfter, "timelocked");
        require(block.timestamp <= p.executeAfter + CREATOR_TRANSFER_GRACE, "proposal expired");

        address old = tokenCreator[token];
        require(old != address(0), "unknown token");
        require(p.newCreator != old, "same creator");

        delete pendingTokenCreator[token];
        tokenCreator[token] = p.newCreator;
        uint256[] storage ids = tokenPositions[token];
        for (uint256 i; i < ids.length; i++) {
            positionsInfo[ids[i]].creator = p.newCreator;
        }
        delete creatorSplits[token];
        emit TokenCreatorSet(token, old, p.newCreator);
    }

    /// @dev Renouncing is disabled. The owner is the only address that can repoint `feeRecipient`
    ///      after a payee becomes un-payable, so an ownerless locker could leave fees permanently
    ///      undeliverable with nobody able to repair it.
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }

    /// @notice Toggle burning of the platform's coin-token fee share. Owner only.
    function setBurnPlatformCoinShare(bool on) external onlyOwner {
        burnPlatformCoinShare = on;
        emit BurnPlatformCoinShareSet(on);
    }

    // --------------------------------------------------------------- creator fee routing

    /// @notice Creator-only: route your creator fee to one or many wallets by bps (sum=10000). Pass a
    ///         single [wallet,10000] to redirect it entirely; pass empty arrays to reset to the
    ///         original creator. Applies to BOTH the coin and quote sides of the fee.
    function setCreatorSplit(address token, address[] calldata recipients, uint256[] calldata bps) external {
        require(msg.sender == tokenCreator[token] && msg.sender != address(0), "not creator");
        require(recipients.length == bps.length && recipients.length <= 20, "bad len");
        delete creatorSplits[token];
        uint256 sum;
        for (uint256 i; i < recipients.length; i++) {
            require(recipients[i] != address(0) && bps[i] > 0, "bad entry");
            sum += bps[i];
            creatorSplits[token].push(Split(recipients[i], bps[i]));
        }
        require(recipients.length == 0 || sum == 10000, "bps!=10000");
        emit CreatorSplitSet(token, msg.sender, recipients.length);
    }

    /// @notice The configured creator-fee recipients for a token (empty = pays the original creator).
    function splitsOf(address token) external view returns (Split[] memory) {
        return creatorSplits[token];
    }

    /// @dev Pay the creator share, honoring a configured split. Last recipient absorbs rounding dust.
    function _payCreator(address t0, address t1, address proj, address creator, uint256 c0, uint256 c1)
        internal
    {
        Split[] storage sp = creatorSplits[proj];
        if (sp.length == 0) {
            _pay(t0, creator, c0);
            _pay(t1, creator, c1);
            return;
        }
        uint256 rem0 = c0;
        uint256 rem1 = c1;
        uint256 last = sp.length - 1;
        for (uint256 i; i <= last; i++) {
            uint256 a0 = i == last ? rem0 : (c0 * sp[i].bps) / 10000;
            uint256 a1 = i == last ? rem1 : (c1 * sp[i].bps) / 10000;
            rem0 -= a0;
            rem1 -= a1;
            _pay(t0, sp[i].to, a0);
            _pay(t1, sp[i].to, a1);
        }
    }

    // ------------------------------------------------------------------ metadata

    /// @notice Metadata URI for any coin we launched: `<base><address>.json`. Answers only for coins
    ///         we actually launched (tokenCreator is set on register), so it can't be used to dress up
    ///         a token that isn't ours. Never reverts: "" when unknown, when no base is set, or if the
    ///         launcher call fails.
    function tokenURI(address token) external view returns (string memory) {
        if (tokenCreator[token] == address(0)) return "";
        try IStonkLauncherBaseURI(launcher).baseTokenURI() returns (string memory base) {
            if (bytes(base).length == 0) return "";
            return string.concat(base, Strings.toHexString(token), ".json");
        } catch {
            return "";
        }
    }

    // ------------------------------------------------------------------ NFT reception (in only)

    /**
     * @dev The position manager's `mint` delivers with plain `_mint`, which never invokes this
     *      callback — every launch NFT already arrives without passing through here (verified on a
     *      mainnet fork: launches register with this hook made unreachable). The ONLY thing that
     *      reaches this function is an ERC-721 `safeTransferFrom` — that is, someone hand-sending a
     *      position NFT into a contract that can never give it back (audit finding L-02). Requiring
     *      `from == address(0)` rejects exactly that and nothing else: a mint-time delivery, on any
     *      hypothetical NPM that DID safe-mint, still passes. Plain `transferFrom` has no hook and
     *      cannot be blocked by any receiver; that residual path stays documented rather than
     *      pretended away.
     */
    function onERC721Received(address, address from, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        require(msg.sender == address(npm), "only NPM NFTs");
        require(from == address(0), "no NFT transfers");
        return IERC721Receiver.onERC721Received.selector;
    }

    // NOTE: there is intentionally NO decreaseLiquidity, NO burn, NO NFT transfer, and NO NFT approval
    // anywhere in this contract. The only position-touching calls are collect() and increaseLiquidity().

    // ------------------------------------------------------------------ UUPS

    /// @dev Upgradeability is permanently disabled by design. This contract custodies every launch's
    ///      LP NFT forever, so the "principal locked forever / rug physically impossible" guarantee
    ///      must be enforced by immutable CODE, not by a revocable owner promise: any upgrade attempt
    ///      reverts unconditionally, for anyone (owner included), from block 0. The proxy pattern is
    ///      retained only for stable addressing + atomic initialization.
    function _authorizeUpgrade(address) internal pure override {
        revert UpgradesFrozen();
    }

    receive() external payable {}

    /// @dev Storage gap for future storage (never for logic upgrades — those are permanently
    ///      disabled). One slot fewer than V1: `pendingFeeSplit` took it.
    uint256[37] private __gap;
}
