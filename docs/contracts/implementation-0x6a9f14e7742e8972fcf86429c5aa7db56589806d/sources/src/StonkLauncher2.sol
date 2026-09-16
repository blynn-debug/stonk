// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {StonkTokenDeployer} from "./StonkTokenDeployer.sol";
import {StonkFeeLocker2} from "./StonkFeeLocker2.sol";
import {StonkQuoteRegistry2} from "./StonkQuoteRegistry2.sol";
import {TickMath08} from "./lib/TickMath08.sol";
import {IV3Factory, IV3Pool, INPM, IWrappedNative} from "./interfaces/IV3.sol";

interface IReferralSplitterSetter {
    function setReferrer(address token, address referrer) external;
}

/**
 * @title StonkLauncher
 * @notice Launches a coin whose ENTIRE supply is placed as ONE single-sided Uniswap V3 position
 *         spanning the full range, priced against a TOKENIZED EQUITY (Base B20) or WETH — on a real
 *         DEX from block 0. No bonding curve, no presale, no migration, no graduation mechanics. The
 *         single LP NFT goes straight to a rug-proof `StonkFeeLocker` (principal locked forever; only
 *         swap fees are ever collectable, split creator / platform / auto-liquidity). The per-launch
 *         ERC-20 (`StonkToken`) is immutable by design.
 *
 * @dev SINGLE-SIDED MATH (project token deposited, 0 quote):
 *      Uniswap prices are token1/token0. A position [tickLower, tickUpper] with current tick `tc`
 *      holds ONLY token0 when tc <= tickLower, and ONLY token1 when tc >= tickUpper.
 *        - If projectToken == token0 (token < quote): range = [launchTick, maxUsableTick], initialize
 *          AT tickLower (tc == tickLower) -> deposits only token0 (project), 0 token1. Buyers push tc
 *          UP into the range as they buy.
 *        - If projectToken == token1 (token > quote): range = [minUsableTick, launchTick], initialize
 *          AT tickUpper (tc == tickUpper) -> deposits only token1 (project), 0 token0. Buyers push tc
 *          DOWN as they buy.
 *      Both orderings occur here: B20 equities all live at 0xb2… so a coin lands below the quote
 *      roughly seven times in ten, and above it otherwise.
 *
 * @dev WHY A ONE-SIDED LAUNCH WORKS BEFORE THE EQUITY MARKET DOES. The position is minted with 100%
 *      project token and ZERO quote, so a coin can be launched against an equity that has no
 *      circulating supply and no pool of its own yet. Nothing about opening a market requires the
 *      quote side to exist first — only trading does.
 *
 * @dev DIFFERENCES FROM THE ETH-PAIRED ANCESTOR. That launchpad ran on a chain whose native gas token
 *      IS its quote asset, so `msg.value` doubled as quote and a dev buy needed no approval. Here the
 *      quote is an ordinary ERC-20 (or WETH), so a dev buy is funded either by pulling the equity with
 *      `transferFrom` — optionally authorized in the same transaction via the ERC-2612 `permit` that
 *      B20 implements — or, for WETH quotes, by wrapping attached ETH. `msg.value` now carries only
 *      the flat platform launch fee plus, for WETH pairs, the dev-buy budget.
 *
 * @dev V2 DELTAS from the launcher live at 0x9e9c…0803:
 *        1. Every launch calls `quoteRegistry.sync(quote)` — a state-changing poke that lets the V2
 *           registry refresh its opening-tick anchor from a Chainlink feed. The call is designed on
 *           the registry side to NEVER revert, so a dead oracle degrades pricing, not availability.
 *        2. `LaunchParams.minDevBuyTokens` — a slippage floor on the dev buy. Pointless under V1's
 *           owner-pinned ticks; necessary now that the opening tick can legitimately move between
 *           signing and inclusion.
 *        3. `launchWithZap` — a dev buy funded in ETH for EQUITY-quoted launches: the attached ETH
 *           is swapped to the quote through a caller-chosen, owner-allowlisted aggregator before
 *           the buy. Venue-agnostic on purpose: wherever equity liquidity lands (Uniswap,
 *           Aerodrome, anywhere an aggregator routes), the same entrypoint works, and the launcher
 *           itself integrates no venue. Output is verified by balance delta against
 *           `zap.minQuoteOut`; the target allowlist plus that check is the entire trust surface.
 */
contract StonkLauncher2 is OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // Protocol addresses, set in initialize().
    IV3Factory public factory;
    INPM public npm;
    StonkFeeLocker2 public feeLocker;
    StonkQuoteRegistry2 public quoteRegistry;
    /// @notice Wrapped native. When a launch's quote IS this token, a dev buy may be funded with ETH.
    address public weth;

    /// @notice Optional flat platform launch fee, in ETH. The real revenue is the fee locker's cut of
    ///         swap fees.
    uint256 public launchFeeWei;

    /// @notice Locked launch supply. When non-zero every launch MUST use exactly this totalSupply.
    ///         Combined with the per-quote launch tick this pins the opening market cap across all
    ///         launches. 0 = unlocked (any supply allowed).
    uint256 public enforcedSupply;

    /// @notice Base for StonkToken.tokenURI(), e.g. "https://thestonks.exchange/t/" (keep the slash).
    string public baseTokenURI;

    /// @notice Referral splitter. When set + the launcher is the splitter's registrar, each ref launch
    ///         names the coin's referrer on-chain in the launch tx. 0 = referrals off.
    address public referralSplitter;

    /// @notice Owner-settable override for the feeLocker.register gas stipend. 0 = default.
    uint256 public feeLockerRegisterGas;


    // Transient guard: the pool currently authorized to invoke our swap callback.
    address private _activePool;

    // CREATE2 salt entropy for the non-salted launch path.
    uint256 private _launchNonce;

    // Gas stipend for the referralSplitter.setReferrer call. try/catch alone doesn't protect against a
    // callee that burns gas instead of cleanly reverting (EIP-150 forwards ~63/64 of remaining gas by
    // default) — the cap bounds what a buggy/malicious splitter can waste.
    uint256 internal constant REFERRER_NAME_GAS = 100_000;
    // Default stipend for feeLocker.register. Unlike the referral call this is NOT try/catch-wrapped —
    // registering the position is load-bearing (an unregistered NFT would strand the creator's fee
    // stream), so a real failure must revert the whole launch. The cap only bounds worst-case gas
    // consumed by a griefing locker implementation.
    uint256 internal constant DEFAULT_FEE_LOCKER_REGISTER_GAS = 300_000;

    /// @notice Coins launch on the 1% tier — the fee split assumes it.
    uint24 public constant LAUNCH_FEE_TIER = 10000;


    struct LaunchParams {
        string name;
        string symbol;
        uint256 totalSupply;
        /// @notice The asset the coin is priced against: a B20 equity, or WETH. Must be enabled in
        ///         the quote registry.
        address quote;
        /// @notice Exact amount of `quote` (RAW units — equities carry 8 decimals, WETH 18) to spend
        ///         buying the coin for the creator in the launch transaction. 0 = no dev buy.
        uint256 devBuyQuote;
        /// @notice Floor on the coin the dev buy must return. The opening tick is live-synced from
        ///         an oracle in V2, so the price a dev buy executes at can differ from the one the
        ///         UI previewed — this bounds that drift exactly like `minOut` bounds a trade.
        ///         MUST be 0 when there is no dev buy.
        uint256 minDevBuyTokens;
        /// @notice Caller-chosen CREATE2 salt for a predictable token address. 0 = derive internally
        ///         from a launcher nonce + the previous blockhash.
        bytes32 userSalt;
        /// @notice The largest platform launch fee, in wei, the caller is willing to pay. The fee is
        ///         read from storage at execution time, so without a cap an owner could raise it
        ///         between signing and inclusion and consume the whole attached value.
        uint256 maxLaunchFeeWei;
        /// @notice Where this coin's creator fees should be paid. 0 = the launching wallet. Set here
        ///         to route the stream to a treasury or cold wallet from the very first trade; the
        ///         launching wallet keeps the right to change it later via
        ///         `StonkFeeLocker.setCreatorSplit`.
        address feeRecipient;
    }

    /// @notice Profile carried IN the launch tx so the frontend needs NO post-launch signature — an
    ///         indexer reads it straight from `TokenMetaSet`. Emit-only: no storage.
    struct Meta {
        string image;
        string banner;
        string description;
        string website;
        string twitter;
        string telegram;
    }

    /// @notice ERC-2612 authorization so a dev buy needs no separate approve tx. B20 implements
    ///         ERC-2612 with an EIP-712 domain of (name, version="1", chainId, verifyingContract).
    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice The ETH→quote leg of a zapped launch: which aggregator to call, with what calldata,
    ///         and the least quote acceptable for the ETH given. The calldata is built off-chain by
    ///         the aggregator's own API; this contract validates the OUTCOME (balance delta ≥
    ///         minQuoteOut), never the route.
    struct Zap {
        address target;
        uint256 minQuoteOut;
        bytes data;
    }

    /// @notice Aggregators `launchWithZap` may call. Owner-curated; the launcher grants them no
    ///         approvals and sends only the launch's own ETH, so a listing gone bad is bounded by
    ///         the per-launch `minQuoteOut` check.
    mapping(address => bool) public zapTargets;

    struct TokenInfo {
        address token;
        address creator;
        address pool;
        address quote;
        uint256 tokenId; // the single full-range position NFT
        uint24 fee;
        uint256 createdAt;
    }

    mapping(address => TokenInfo) public tokenInfo;
    address[] public allTokens;

    event TokenLaunched(
        address indexed token,
        uint256 indexed tokenId,
        address indexed creator,
        address quote,
        address pool,
        uint24 fee,
        int24 launchTick,
        uint256 totalSupply,
        /// @notice The locker that received this launch's LP NFT. Recorded so anyone can verify, per
        ///         launch, that the position went to the rug-proof locker and not somewhere else.
        address feeLocker
    );
    event TokenMetaSet(
        address indexed token,
        address indexed creator,
        string image,
        string banner,
        string description,
        string website,
        string twitter,
        string telegram
    );
    /// @notice Emitted only for the salted launch family so an indexer reconstructing launch history
    ///         purely from logs can recover which userSalt produced a given token.
    event SaltedLaunch(address indexed token, bytes32 userSalt);
    event DevBuy(address indexed token, address indexed creator, uint256 quoteSpent, uint256 tokensOut);
    event LaunchFeeSet(uint256 amountWei);
    event ZapTargetSet(address indexed target, bool allowed);
    event EnforcedSupplySet(uint256 supply);
    event BaseTokenURISet(string base);
    event QuoteRegistrySet(address indexed registry);
    event ReferralSplitterSet(address indexed splitter);
    event FeeLockerRegisterGasSet(uint256 gas_);

    error FeeLockerRegisterGasTooLow();
    error QuoteNotEnabled(address quote);
    error PoolPreInitialized();
    error InsufficientValue();
    error LaunchFeeTooHigh(uint256 current, uint256 max);
    error SupplyLocked();
    error BadFeeTier();
    error BadTickMagnitude();
    error SaltUsed();
    error DevBuySlippage();
    error ZapTargetNotAllowed(address target);
    error ZapUnnecessary(); // the quote is WETH: fund the dev buy with plain attached ETH instead
    error ZapConflicts();   // a zap supplies the dev-buy quote, so devBuyQuote must be 0
    error ZapFailed();
    error ZapSlippage(uint256 got, uint256 min);
    /// @dev Upgrades are permanently disabled by design — see _authorizeUpgrade.
    error UpgradesFrozen();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_,
        address npm_,
        address feeLocker_,
        address quoteRegistry_,
        address weth_,
        address owner_,
        uint256 enforcedSupply_
    ) external initializer {
        require(factory_ != address(0) && npm_ != address(0), "zero addr");
        require(feeLocker_ != address(0) && quoteRegistry_ != address(0) && weth_ != address(0), "zero addr");
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        factory = IV3Factory(factory_);
        npm = INPM(npm_);
        feeLocker = StonkFeeLocker2(payable(feeLocker_));
        quoteRegistry = StonkQuoteRegistry2(quoteRegistry_);
        weth = weth_;
        enforcedSupply = enforcedSupply_;
    }

    // -----------------------------------------------------------------------
    // Launch
    // -----------------------------------------------------------------------

    /// @notice Launch a coin against `p.quote`: deploys an immutable token and places its entire
    ///         supply as a single-sided full-range V3 position, locked forever in the fee locker.
    function launch(LaunchParams calldata p) external payable nonReentrant returns (address, uint256) {
        return _launch(p, address(0));
    }

    /// @notice One-tap launch: sets the coin's profile atomically in the SAME transaction, so no
    ///         signature is ever needed to save the logo/banner/socials.
    function launchWithMeta(LaunchParams calldata p, Meta calldata meta)
        external
        payable
        nonReentrant
        returns (address token, uint256 tokenId)
    {
        (token, tokenId) = _launch(p, address(0));
        _emitMeta(token, meta);
    }

    /// @notice launchWithMeta() + on-chain referral attribution (from the creator's ?ref= link).
    function launchWithMetaRef(LaunchParams calldata p, Meta calldata meta, address referrer)
        external
        payable
        nonReentrant
        returns (address token, uint256 tokenId)
    {
        (token, tokenId) = _launch(p, referrer);
        _emitMeta(token, meta);
    }

    /**
     * @notice launchWithMetaRef() where the dev buy's quote allowance is authorized by an ERC-2612
     *         signature in the same transaction — so launching with a dev buy against a B20 equity is
     *         ONE wallet action instead of approve-then-launch.
     * @dev The permit is best-effort: if it reverts because an equivalent allowance already landed
     *      (a front-run of the same signature, or a prior approve), the launch proceeds and the
     *      subsequent `transferFrom` is the real authorization check. Any other failure surfaces there.
     */
    function launchWithPermit(
        LaunchParams calldata p,
        Meta calldata meta,
        address referrer,
        PermitData calldata permit
    ) external payable nonReentrant returns (address token, uint256 tokenId) {
        // Check the quote is one we listed BEFORE making a full-gas call to a caller-chosen address,
        // and require the authorization to be exactly the dev buy so no standing allowance survives.
        if (!quoteRegistry.isEnabled(p.quote)) revert QuoteNotEnabled(p.quote);
        require(permit.value == p.devBuyQuote, "permit != devBuy");
        if (permit.value > 0) {
            try IERC20Permit(p.quote).permit(
                msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s
            ) {} catch {}
        }
        (token, tokenId) = _launch(p, referrer);
        _emitMeta(token, meta);
    }

    /**
     * @notice launchWithMetaRef() where the dev buy is funded in ETH and routed to the quote asset
     *         through an allowlisted aggregator — so a creator holding only ETH can launch against
     *         a tokenized equity with a dev buy in one wallet action.
     *
     * @dev The attached ETH beyond the launch fee is sent, in full, to `zap.target` with
     *      `zap.data`; whatever `quote` the launcher's balance gained is the dev-buy budget,
     *      required to be at least `zap.minQuoteOut`. Any native ETH the aggregator refunds
     *      (positive slippage, unused input) is returned to the caller after the launch. ETH the
     *      route leaves as WETH is NOT unwrapped here — build routes that refund native or nothing.
     */
    function launchWithZap(LaunchParams calldata p, Meta calldata meta, address referrer, Zap calldata zap)
        external
        payable
        nonReentrant
        returns (address token, uint256 tokenId)
    {
        if (!zapTargets[zap.target]) revert ZapTargetNotAllowed(zap.target);
        if (p.quote == weth) revert ZapUnnecessary();
        if (p.devBuyQuote != 0) revert ZapConflicts();
        // Fail the cheap checks before granting a full-gas call to an external router.
        if (launchFeeWei > p.maxLaunchFeeWei) revert LaunchFeeTooHigh(launchFeeWei, p.maxLaunchFeeWei);
        if (msg.value < launchFeeWei) revert InsufficientValue();
        uint256 ethBudget = msg.value - launchFeeWei;
        if (ethBudget == 0) revert InsufficientValue();

        uint256 quoteBefore = IERC20(p.quote).balanceOf(address(this));
        uint256 balBefore = address(this).balance; // msg.value already credited
        (bool ok,) = zap.target.call{value: ethBudget}(zap.data);
        if (!ok) revert ZapFailed();
        uint256 got = IERC20(p.quote).balanceOf(address(this)) - quoteBefore;
        if (got == 0 || got < zap.minQuoteOut) revert ZapSlippage(got, zap.minQuoteOut);
        // Whatever ETH came back beyond what we sent is the aggregator's refund to the creator.
        uint256 ethBack = address(this).balance - (balBefore - ethBudget);

        (token, tokenId) = _launchCore(p, referrer, got, true);
        _emitMeta(token, meta);
        if (ethBack > 0) _sendEth(msg.sender, ethBack);
    }

    /// @notice Off-chain address prediction for the salted path. `creator` MUST be the exact address
    ///         that will be msg.sender for the matching launch call. Note this fixes the token ADDRESS
    ///         only — none of `_launch`'s other gates are checked here.
    function predictTokenAddress(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        address creator,
        bytes32 userSalt
    ) external view returns (address) {
        return StonkTokenDeployer.predictToken(
            name, symbol, totalSupply, address(this), creator, keccak256(abi.encode(creator, userSalt))
        );
    }

    // -----------------------------------------------------------------------
    // Launch internals
    // -----------------------------------------------------------------------

    function _launch(LaunchParams calldata p, address referrer)
        internal
        returns (address token, uint256 tokenId)
    {
        return _launchCore(p, referrer, 0, false);
    }

    /// @param zappedQuote Quote already sitting in this launcher, obtained by `launchWithZap`'s
    ///        aggregator leg. Meaningful only when `zapped` is true.
    function _launchCore(LaunchParams calldata p, address referrer, uint256 zappedQuote, bool zapped)
        internal
        returns (address token, uint256 tokenId)
    {
        require(p.totalSupply > 0, "supply=0");
        if (enforcedSupply != 0 && p.totalSupply != enforcedSupply) revert SupplyLocked();
        if (!quoteRegistry.isEnabled(p.quote)) revert QuoteNotEnabled(p.quote);
        if (launchFeeWei > p.maxLaunchFeeWei) revert LaunchFeeTooHigh(launchFeeWei, p.maxLaunchFeeWei);
        if (msg.value < launchFeeWei) revert InsufficientValue();

        // 0. Let the registry refresh this quote's opening tick from its oracle. Designed on the
        //    registry side to NEVER revert: a stale or dead feed leaves the stored anchor in place,
        //    so pricing can degrade but a launch cannot be blocked by an oracle.
        quoteRegistry.sync(p.quote);

        // 1. Deploy the immutable token; all supply minted to this launcher (CREATE2, salted).
        token = _deployToken(p);

        // 2-4. Open the pool at the quote's launch tick and mint the single locked position.
        address pool;
        int24 launchTick;
        (pool, tokenId, launchTick) = _openPoolAndMint(token, p.quote, p.totalSupply, p.feeRecipient);

        // Name the referrer on-chain, atomically. try/catch + gas cap so a bad referrer or an
        // unset/misconfigured splitter can never block a launch. Self-referral is a silent no-op.
        if (referrer != address(0) && referrer != msg.sender && referralSplitter != address(0)) {
            try IReferralSplitterSetter(referralSplitter).setReferrer{gas: REFERRER_NAME_GAS}(token, referrer) {}
                catch {}
        }

        // 5. Optional dev buy for the creator: funded by the zap leg when zapped, by pulling (or
        //    wrapping) the quote otherwise.
        if (zapped) {
            _settleZapped(token, pool, p.quote, zappedQuote, p.minDevBuyTokens);
        } else {
            _settleFunds(token, pool, p.quote, p.devBuyQuote, p.minDevBuyTokens);
        }

        // 6. Sweep any project-token dust; registry.
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).safeTransfer(msg.sender, dust);

        _record(p, token, pool, tokenId, launchTick);
    }

    /// @dev Deploy the immutable coin. The default salt mixes a per-launcher nonce + the previous
    ///      blockhash; the `livePrice == sqrtLaunch` check in `_openPoolAndMint` is the funds-safe
    ///      backstop against anyone pre-initializing the pool at a skewed price.
    function _deployToken(LaunchParams calldata p) internal returns (address token) {
        bytes32 salt = p.userSalt != bytes32(0)
            ? keccak256(abi.encode(msg.sender, p.userSalt))
            : keccak256(
                abi.encode(
                    msg.sender, p.name, p.symbol, p.totalSupply, _launchNonce++, blockhash(block.number - 1)
                )
            );
        if (p.userSalt != bytes32(0)) {
            // A salted retry (same tuple resubmitted) hits CREATE2 at the EVM level with NO revert
            // string at all — give retry tooling a clean, actionable reason instead.
            address predicted =
                StonkTokenDeployer.predictToken(p.name, p.symbol, p.totalSupply, address(this), msg.sender, salt);
            if (predicted.code.length != 0) revert SaltUsed();
        }
        token = StonkTokenDeployer.deployToken(p.name, p.symbol, p.totalSupply, address(this), msg.sender, salt);
    }

    /// @dev Persist the launch and announce it. Split out of `_launch` purely to keep that function
    ///      inside the EVM's reachable stack window.
    function _record(LaunchParams calldata p, address token, address pool, uint256 tokenId, int24 launchTick)
        internal
    {
        tokenInfo[token] = TokenInfo({
            token: token,
            creator: msg.sender,
            pool: pool,
            quote: p.quote,
            tokenId: tokenId,
            fee: LAUNCH_FEE_TIER,
            createdAt: block.timestamp
        });
        allTokens.push(token);

        emit TokenLaunched(
            token, tokenId, msg.sender, p.quote, pool, LAUNCH_FEE_TIER, launchTick, p.totalSupply, address(feeLocker)
        );
        if (p.userSalt != bytes32(0)) emit SaltedLaunch(token, p.userSalt);
    }

    /// @dev Create + initialize the pool at the quote's launch tick, then mint the ONE single-sided
    ///      full-range position straight into the fee locker and register it there.
    function _openPoolAndMint(address token, address quote, uint256 totalSupply, address feeRecipient)
        internal
        returns (address pool, uint256 tokenId, int24 launchTick)
    {
        int24 lower;
        int24 upper;
        (launchTick, lower, upper) = _band(token, quote);

        uint160 sqrtLaunch = TickMath08.getSqrtRatioAtTick(launchTick);
        pool = npm.createAndInitializePoolIfNecessary(
            token < quote ? token : quote, token < quote ? quote : token, LAUNCH_FEE_TIER, sqrtLaunch
        );
        (uint160 livePrice,,,,,,) = IV3Pool(pool).slot0();
        if (livePrice != sqrtLaunch) revert PoolPreInitialized();

        IERC20(token).forceApprove(address(npm), totalSupply);
        (tokenId,,,) = npm.mint(
            INPM.MintParams({
                token0: token < quote ? token : quote,
                token1: token < quote ? quote : token,
                fee: LAUNCH_FEE_TIER,
                tickLower: lower,
                tickUpper: upper,
                // The whole supply on the project side, ZERO quote — this is what makes a launch
                // possible against an equity that has no circulating supply yet.
                amount0Desired: token < quote ? totalSupply : 0,
                amount1Desired: token < quote ? 0 : totalSupply,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(feeLocker),
                deadline: block.timestamp
            })
        );

        // Gas-capped so a griefing locker implementation can't burn ~63/64 of remaining gas; a real
        // failure still reverts the whole launch (registering is load-bearing — see the constant).
        uint256 stipend = feeLockerRegisterGas == 0 ? DEFAULT_FEE_LOCKER_REGISTER_GAS : feeLockerRegisterGas;
        feeLocker.register{gas: stipend}(tokenId, msg.sender, quote, feeRecipient);
    }

    /// @dev The single full-range band, and the tick the pool opens at. Reverts for an unregistered
    ///      quote, so a launch can never open at parity (tick 0 — a wildly mispriced pool) by
    ///      accident. The magnitude is aligned DOWN to the tier's spacing, which V3 requires of range
    ///      bounds, and the sign comes from token ordering (see the contract-level note).
    function _band(address token, address quote)
        internal
        view
        returns (int24 launchTick, int24 lower, int24 upper)
    {
        int24 spacing = 200; // the 1% tier's spacing
        int24 maxUsable = (TickMath08.MAX_TICK / spacing) * spacing;
        int24 alignedMag = (quoteRegistry.launchTickMagnitude(quote) / spacing) * spacing;
        if (alignedMag <= 0 || alignedMag >= maxUsable) revert BadTickMagnitude();

        if (token < quote) {
            launchTick = -alignedMag; // buyers push the tick UP: band = [launch, max]
            lower = launchTick;
            upper = maxUsable;
        } else {
            launchTick = alignedMag; // buyers push the tick DOWN: band = [min, launch]
            lower = (TickMath08.MIN_TICK / spacing) * spacing;
            upper = launchTick;
        }
    }

    // -----------------------------------------------------------------------
    // Dev buy + ETH settlement
    // -----------------------------------------------------------------------

    /**
     * @dev Fund and execute the optional dev buy, then return every unspent wei.
     *
     *      Funding depends on the quote:
     *        - quote == WETH: the dev buy is paid in ETH. `msg.value` must cover the launch fee PLUS
     *          `devBuyQuote`, which is wrapped here. Leftover ETH goes back to the creator.
     *        - otherwise: `devBuyQuote` raw units of the equity are pulled from the creator with
     *          `transferFrom` (allowance from a prior approve, or from the ERC-2612 permit spent in
     *          `launchWithPermit`). All ETH beyond the launch fee is returned untouched.
     *
     *      Unspent quote — the swap can stop early only by hitting the band's price limit — is
     *      returned in whatever the creator actually paid: ETH for a WETH pair, the equity otherwise.
     */
    function _settleFunds(address token, address pool, address quote, uint256 devBuyQuote, uint256 minTokensOut)
        internal
    {
        uint256 ethBudget = msg.value - launchFeeWei;

        if (devBuyQuote == 0) {
            // A floor with nothing under it is a signed intention this launch cannot honor.
            if (minTokensOut != 0) revert DevBuySlippage();
            if (ethBudget > 0) _sendEth(msg.sender, ethBudget);
            return;
        }

        bool ethFunded = quote == weth;
        if (ethFunded) {
            if (ethBudget < devBuyQuote) revert InsufficientValue();
            IWrappedNative(weth).deposit{value: devBuyQuote}();
            ethBudget -= devBuyQuote;
        } else {
            IERC20(quote).safeTransferFrom(msg.sender, address(this), devBuyQuote);
        }

        (uint256 spent, uint256 got) = _swapQuoteForToken(pool, token, quote, devBuyQuote, msg.sender);
        if (got < minTokensOut) revert DevBuySlippage();
        uint256 unspent = devBuyQuote - spent;

        if (unspent > 0) {
            if (ethFunded) {
                IWrappedNative(weth).withdraw(unspent);
                ethBudget += unspent;
            } else {
                IERC20(quote).safeTransfer(msg.sender, unspent);
            }
        }
        if (ethBudget > 0) _sendEth(msg.sender, ethBudget);
    }

    /// @dev The zapped counterpart: the quote is ALREADY in this contract (the aggregator leg put
    ///      it there), so there is nothing to pull and no ETH budget to account — `launchWithZap`
    ///      returns the aggregator's own refund separately. Quote the band edge left unconsumed
    ///      goes back to the creator as the equity itself.
    function _settleZapped(address token, address pool, address quote, uint256 quoteIn, uint256 minTokensOut)
        internal
    {
        (uint256 spent, uint256 got) = _swapQuoteForToken(pool, token, quote, quoteIn, msg.sender);
        if (got < minTokensOut) revert DevBuySlippage();
        uint256 unspent = quoteIn - spent;
        if (unspent > 0) IERC20(quote).safeTransfer(msg.sender, unspent);
    }

    /// @dev Exact-input swap of `amountIn` quote on the fresh pool; the coin goes straight to
    ///      `recipient`. Returns the quote actually consumed and the coin received — V2 callers
    ///      enforce `minDevBuyTokens` against the latter.
    function _swapQuoteForToken(
        address pool,
        address token,
        address quote,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256 spent, uint256 got) {
        // Buying the coin WITH quote: zeroForOne is true when the quote is token0.
        bool zeroForOne = quote < token;
        uint160 limit = zeroForOne ? TickMath08.MIN_SQRT_RATIO + 1 : TickMath08.MAX_SQRT_RATIO - 1;

        _activePool = pool;
        (int256 a0, int256 a1) = IV3Pool(pool).swap(recipient, zeroForOne, amountIn.toInt256(), limit, "");
        _activePool = address(0);

        // Exactly one delta is positive: the input the pool consumed.
        spent = uint256(zeroForOne ? a0 : a1);
        got = uint256(-(zeroForOne ? a1 : a0));
        emit DevBuy(token, recipient, spent, got);
    }

    /// @dev Uniswap V3 swap callback: pay the pool the quote input it is owed. Guarded by the
    ///      transient `_activePool` so no third party can drain an allowance through this entrypoint.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == _activePool && _activePool != address(0), "unauth cb");
        if (amount0Delta > 0) {
            IERC20(IV3Pool(msg.sender).token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IV3Pool(msg.sender).token1()).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    /// @notice Lock the launch supply (0 = unlocked). When set, every launch must use exactly this
    ///         totalSupply, which — with the per-quote launch tick — fixes the opening market cap.
    function setEnforcedSupply(uint256 supply) external onlyOwner {
        enforcedSupply = supply;
        emit EnforcedSupplySet(supply);
    }

    /// @notice Set the base every token's tokenURI() is built from. Include the trailing slash. Read
    ///         live, so one call retroactively moves every coin. "" = no metadata.
    function setBaseTokenURI(string calldata base) external onlyOwner {
        baseTokenURI = base;
        emit BaseTokenURISet(base);
    }

    function setLaunchFee(uint256 amountWei) external onlyOwner {
        launchFeeWei = amountWei;
        emit LaunchFeeSet(amountWei);
    }

    /**
     * @notice THERE IS DELIBERATELY NO WAY TO CHANGE THE FEE LOCKER.
     *
     * @dev `feeLocker` is written once in `initialize` and never again. This is the single most
     *      consequential address in the system: it is where `npm.mint` sends the LP NFT holding a
     *      launch's ENTIRE supply. A setter — even a timelocked one — would mean an owner with a
     *      compromised key could eventually point the next launch at a contract that calls
     *      `decreaseLiquidity`, turning a launchpad whose whole claim is "the principal can never
     *      leave" into a rug, with honest and hostile launches indistinguishable in the logs.
     *
     *      A delay would only have made that attacker wait. The setter's sole legitimate use was
     *      adopting an improved locker for future launches one day — a speculative benefit, since one
     *      locker serves every coin and already-locked positions could never move to it anyway. A new
     *      locker is a different trust model, so it deserves a new launcher and a visibly different
     *      address rather than a silent repoint of this one.
     *
     *      `TokenLaunched` records the receiving locker per launch, so the guarantee is verifiable
     *      from logs alone and not merely asserted here.
     */

    /// @notice Repoint the quote registry used by NEW launches (to add equities as Base lists them, or
    ///         to migrate to a re-architected registry). Affects which assets may be paired and at
    ///         what opening tick; it cannot touch any existing pool or locked position.
    function setQuoteRegistry(address registry_) external onlyOwner {
        require(registry_ != address(0), "registry=0");
        quoteRegistry = StonkQuoteRegistry2(registry_);
        emit QuoteRegistrySet(registry_);
    }

    /// @notice Curate the aggregators `launchWithZap` may route through. Adding one grants it no
    ///         approvals and no custody — only the right to receive a launch's ETH leg, whose
    ///         output the caller's own `minQuoteOut` still gates.
    function setZapTarget(address target, bool allowed) external onlyOwner {
        require(target != address(0), "target=0");
        zapTargets[target] = allowed;
        emit ZapTargetSet(target, allowed);
    }

    function setReferralSplitter(address s) external onlyOwner {
        referralSplitter = s;
        emit ReferralSplitterSet(s);
    }

    /// @notice Owner-settable override for the feeLocker.register gas stipend. 0 = use the default. A
    ///         nonzero override must clear a floor comfortably below any plausible real register()
    ///         cost, so it only ever catches a clear mistake (a typo'd low value would brick every
    ///         launch — register() is deliberately not try/catch-wrapped).
    function setFeeLockerRegisterGas(uint256 gas_) external onlyOwner {
        // register() measures ~155k on a fork; a floor below that would brick EVERY launch, since
        // the call is deliberately not try/catch-wrapped. 250k keeps real headroom above the measurement.
        if (gas_ != 0 && gas_ < 250_000) revert FeeLockerRegisterGasTooLow();
        feeLockerRegisterGas = gas_;
        emit FeeLockerRegisterGasSet(gas_);
    }

    /// @dev Renouncing is disabled. `withdrawFees` is `onlyOwner` and is the ONLY way accumulated
    ///      launch-fee ETH can leave this contract, and upgrades are frozen — an ownerless launcher
    ///      would trap that ETH permanently.
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }

    function withdrawFees() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "no fees");
        _sendEth(owner(), bal);
    }

    /// @notice Sweep a stray ERC-20 accidentally sent to the launcher to the owner. Launches are
    ///         atomic + nonReentrant, so between them the launcher custodies no user funds — this can
    ///         only ever move genuinely stray tokens.
    function rescueToken(address token_) external onlyOwner {
        uint256 bal = IERC20(token_).balanceOf(address(this));
        require(bal > 0, "nothing");
        IERC20(token_).safeTransfer(owner(), bal);
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    function _emitMeta(address token, Meta calldata m) internal {
        emit TokenMetaSet(
            token, msg.sender, m.image, m.banner, m.description, m.website, m.twitter, m.telegram
        );
    }

    /// @dev If `to` rejects this transfer, the WHOLE launch reverts instead of the leftover silently
    ///      staying in this contract — fairness to the sender over convenience. Callers whose smart
    ///      account can't receive plain ETH must route through one that can.
    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "eth send");
    }

    // -----------------------------------------------------------------------
    // UUPS
    // -----------------------------------------------------------------------

    /// @dev Upgradeability is permanently disabled by design: any upgrade attempt reverts
    ///      unconditionally, for anyone, from block 0. The launcher only custodies funds atomically
    ///      inside a single nonReentrant launch, but freezing its logic too means the whole system's
    ///      behavior is immutable — no privileged key can ever change how launches mint, lock, or
    ///      route liquidity. Owner powers are limited to the parameter setters above, none of which
    ///      touch the already-locked principal in the fee locker.
    function _authorizeUpgrade(address) internal pure override {
        revert UpgradesFrozen();
    }

    /// @dev Accepts ETH from the WETH contract on the unwrap path, from aggregators refunding a
    ///      zap leg's unused input (and stray sends, sweepable by the owner). Never used to custody
    ///      user funds across transactions.
    receive() external payable {}

    /// @dev Storage gap for future storage (never for logic upgrades — those are permanently
    ///      disabled). One slot fewer than V1: `zapTargets` took it.
    uint256[39] private __gap;
}
