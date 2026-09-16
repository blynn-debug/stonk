// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Wrapped native ETH. The treasury wraps only what a swap consumes; it never parks WETH by design.
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * StonkFeeLocker2 (verified on-chain, upgrades permanently frozen) — the launchpad's registry and
 * paymaster in one, and the only two things a treasury needs from a launchpad: who it says a coin
 * pays, and how that payment is collected.
 *
 * `tokenCreator` is what makes binding self-verifying. A contract cannot read past events, so a
 * launch registry has to answer as a VIEW for `bind()` to prove anything — and this one does.
 */
/// One entry of a creator's fee split, as the locker stores it.
struct Split {
    address to;
    uint256 bps;
}

interface IStonkFeeLocker {
    /// The wallet the locker pays a coin's creator fees to. Moving it is owner-only behind a 24-hour
    /// announced timelock, and the move CLEARS any configured split — so a treasury holding this role
    /// holds the whole creator stream and nobody, the creator included, can route it elsewhere.
    function tokenCreator(address token) external view returns (address);

    /// The asset a coin was launched against. What the paired leg of every fee is denominated in.
    function tokenQuote(address token) external view returns (address);

    /**
     * Where the creator's fees are actually paid, which is NOT always the creator.
     *
     * This is the slot a launch writes when it names a `feeRecipient`, and the one `_payCreator`
     * consults first: a non-empty split wins over the creator role entirely. Reading the role alone
     * would have proved the wrong thing — a treasury can hold the role and still be paid nothing
     * because a split points elsewhere.
     */
    function splitsOf(address token) external view returns (Split[] memory);

    /// Positions the locker holds for a coin. Zero of them means `collectAll` would revert.
    function positionsOf(address token) external view returns (uint256[] memory);

    /**
     * Collect the pool's earned fees into the ledger AND split them out to their payees, for every
     * position of a coin. Permissionless by design — funds can only reach the creator, the platform
     * or back into liquidity — which is what lets `harvest()` stay permissionless too.
     *
     * Reverts with "no positions" for a coin the locker never registered.
     */
    function collectAll(address token) external;

    /**
     * Withdraw a payout that could not be delivered when it was collected.
     *
     * The locker pays with a low-level transfer and, when that fails, credits `claimable` instead of
     * reverting the whole collect. A treasury that only called `collectAll` would leave those
     * balances stranded, so harvest sweeps both sides after collecting. Reverts with
     * "nothing to claim" when there is nothing — which is the ordinary case, hence best-effort.
     */
    function claim(address token) external;
}

/// Config the clones read from the factory on every use, so a locker move is one write for all.
interface IIndexFactory {
    function weth() external view returns (address);
    function launchpads(uint8 id) external view returns (address registry, uint8 kind, bool enabled);
    function launchpadList() external view returns (uint8[] memory);
    /// Venues a swap may be pointed at. An allowlist, not a stored router — see the factory.
    function venue(address target) external view returns (bool);
    function platformFeeBps() external view returns (uint16);
    function platformFeeRecipient() external view returns (address);
    function keeper(address account) external view returns (bool);
}

/// ┌─────────────────────────────────────────────────────────────────────────────────────────────┐
/// │  IndexTreasury — turns a Stonks launch's creator fees into equity paid out to holders.      │
/// └─────────────────────────────────────────────────────────────────────────────────────────────┘
///
/// A coin launched on Stonks names this contract as its `tokenCreator` in the fee locker. From there
/// the cycle is: `harvest()` pulls the fees, `swap()` turns them into tokenized equity at an
/// allowlisted venue, and `distribute()` pushes that equity to coin holders pro-rata on balance. One
/// EIP-1167 clone per coin.
///
/// TWO TIERS OF PROMISE, AND THE DEFAULT IS THE WEAKER ONE. The locker pays whoever the coin's
/// creator SPLIT names, and falls back to the creator ROLE only when no split is set. A launch that
/// names this treasury as its `feeRecipient` produces the first: the launching wallet keeps the role
/// and can repoint the split at itself in one transaction, with no delay and no signature from us.
/// The role is beyond its reach — but a treasury can only hold it through the launchpad owner's
/// announced, timelocked transfer, which is a manual ceremony and never the product of a launch.
///
/// So `bindIsPermanent` is false for every organically launched coin and true only after that
/// ceremony. It is stored so the site can state which promise is actually in force instead of
/// printing one sentence over two very different guarantees. A revoked split does not take back what
/// has already been bought and distributed — it ends the programme rather than looting it — which is
/// what makes the weaker tier a product at all rather than a trap.
///
/// There is deliberately NO price oracle. Gating a swap on a price feed means an equity with no feed
/// can be configured but never bought: the fees arrive and are stuck for good. Here the fill is
/// protected instead by the `minBuyAmount` the keeper carries from its quote, which this contract
/// verifies against the real balance delta. A weaker guarantee than a feed, and the price of
/// supporting any equity a venue can trade.
///
/// TRUST MODEL — what each party can and cannot do:
///   • KEEPER (the service) runs `swap()` and `distribute*()`. It must be gated: the distribution
///     denominator is the sum of the balances of the list it passes, so an open entrypoint let anyone
///     pass `[self]` and take a whole round. Even gated it is NOT trusted with funds — it can only
///     call a venue the factory has allowlisted, only buy basket tokens, never sell a stock back,
///     never spend more quote than it declares (measured, not asserted), and never set payout
///     weights: those are read from `balanceOf(coin)` here, over a list that must be strictly
///     ascending, so no address can appear twice inside a round.
///   • OWNER (the coin's creator) can do NOTHING here. It is a label, not a role: the creator points
///     their launch's fees at this treasury and their involvement ends there. Configuration, pausing
///     and rescue are all the keeper's, so a creator cannot freeze their holders' payouts, cannot
///     shape a distribution, and cannot reach a balance. The service is what runs the treasury; the
///     creator is what funds it.
///   • CREATOR accrues `creatorShareBps` of every harvest, fenced off from `swap()` in both
///     directions, so holder money and creator money can never be spent on each other.
contract IndexTreasury {
    // Payout cadence: what the service offers in the wizard, enforced here so no clone can sit outside it.
    uint32 public constant MIN_INTERVAL = 900; // 15 minutes
    uint32 public constant MAX_INTERVAL = 604_800; // 1 week

    /// Whole coins a wallet must hold to be paid. Dust holders cost ~60k gas to pay in fractions of a
    /// cent; their slice stays with the holders above the line. Resolved against the coin's decimals
    /// at bind time.
    uint256 public constant MIN_HOLDER_COINS = 10_000;

    /**
     * The collection SHAPES this implementation speaks. Registries are configured on the factory; a
     * shape is code and therefore lives here.
     *
     * Adding a launchpad that speaks a shape already listed costs one `setLaunchpad` call. Adding one
     * that speaks a genuinely new shape costs a new implementation — which affects FUTURE clones
     * only, so nobody who already routed fees here wakes up to different logic. That split is the
     * whole design: configuration is cheap and reversible, semantics are not.
     */
    /// A locker keyed on a creator role, paying both legs as ERC20s, with deferred payouts behind a
    /// per-asset `claim`. Speaks: splitsOf · tokenCreator · tokenQuote · positionsOf · collectAll ·
    /// claim. `splitsOf` is the PRIMARY input to the bind predicate — a registry of this kind
    /// without it would bind off the role and pay somebody else.
    /// StonkFeeLocker2 on Base.
    uint8 internal constant KIND_CREATOR_LOCKER = 0;

    /**
     * Which generation of the service this is.
     *
     * Read on-chain rather than inferred from an address: when a later generation ships, a treasury
     * created under this one keeps the logic it was created with — clones are never upgraded — so
     * the only honest way to tell them apart is to ask them.
     */
    string public constant VERSION = "stockify-indices-1";


    /**
     * What the fees are turned into. Chosen once, at creation, and never again — it is the promise
     * the launch was marketed on, and a treasury that could switch it mid-life would be a treasury
     * whose holders were told one thing and given another.
     */
    /// Buy the basket and push it to holders pro-rata. One or many equities.
    uint8 public constant MODE_DISTRIBUTE = 0;
    /// Buy the coin itself and destroy it. No basket, no holder list, no rounds — supply just falls.
    uint8 public constant MODE_BUYBACK_BURN = 1;

    /// Where a coin's own fees go. The locker pays part of every fee in the launched token itself,
    /// and a treasury that buys equity has no use for it — burning is what its holders asked for.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------- storage
    // Order is de-facto ABI for anyone reading storage directly: do not reorder.

    address public factory; // who cloned us: source of venues/weth/feeLocker/keeper
    address public owner; // configures and pauses
    address public creator; // receives creatorShareBps of every harvest
    address public coin; // the launch token: defines WHO gets paid
    address public quote; // asset the fees arrive in: address(0) = native ETH

    address[] public basket; // stocks to buy
    uint16[] public weights; // bps, sums to 10_000
    uint32 public interval; // minimum seconds between two rounds of the same stock
    uint8 public mode; // MODE_DISTRIBUTE | MODE_BUYBACK_BURN — immutable after initialize
    /**
     * How this treasury came to be paid, and therefore how strong the promise to holders is.
     *
     * True only when the treasury holds the launchpad's creator ROLE, which no one but the
     * launchpad's owner can move and only behind an announced timelock. False when it is merely the
     * configured split recipient — which the launching wallet can repoint at itself at any moment,
     * with no notice and no signature from us.
     *
     * Stored rather than derived so the site can state which one is in force instead of printing the
     * same sentence over two very different guarantees.
     */
    bool public bindIsPermanent;

    /**
     * How much of the quote held right now has ALREADY had the platform fee and the creator's share
     * taken off it.
     *
     * `harvest` used to measure a delta across its own collect, which quietly assumed it was the
     * only way fees could arrive. It is not: the locker's `collectAll` is permissionless by design,
     * so anyone could push a treasury's fees in outside a harvest and the later harvest would see a
     * delta of zero — no platform fee, no creator accrual, and the whole amount spendable on
     * holders. A watermark closes it: what counts is everything held that has not been split yet,
     * however it got here.
     */
    uint256 public accountedQuote;

    bool public paused;
    uint16 public creatorShareBps; // what the creator keeps of what reaches this treasury
    uint256 public creatorClaimable; // accrued for the creator, in `quote` — never spendable by swap()
    uint256 public minDistribution; // below this a round is not worth its gas
    uint256 public minHolderBalance; // MIN_HOLDER_COINS scaled to the coin's decimals
    uint32 public batchWindow; // window to finish an already-open round in further txs

    mapping(address => bool) public excluded; // out of the payout (pool, curve, treasury…)
    mapping(uint256 => uint256) public lastDistribution; // basketIdx => round opened at
    mapping(uint256 => uint256) public roundBudget; // basketIdx => what the open round may pay in total
    mapping(uint256 => uint256) public roundPaid; // basketIdx => paid so far in the open round
    mapping(uint256 => address) public roundCursor; // basketIdx => highest holder paid in the open round

    /**
     * Quote asset set aside for holders, when the basket holds the very asset the fees arrive in.
     *
     * A launch paired against NVDA pays its creator fees in NVDA, and its creator usually wants NVDA
     * in the basket — at which point one balance means three different things at once: fees not yet
     * spent, the creator's accrued share, and stock already bought for holders. `distribute()` pays
     * out a whole balance, so without a way to tell them apart it would hand over all three.
     *
     * This is that way. For this one entry nothing is ever bought — the fees already ARE the asset —
     * so the keeper moves value across with `allocate()` instead of a swap, and this is the only
     * part of the balance a round may pay out.
     */
    uint256 public allocatedQuote;

    /**
     * Which launchpad this treasury's coin came from — decided by `bind()`, never configured.
     *
     * Both launchpads publish a view naming who a coin pays, so binding can simply ask each in turn
     * and let whichever one recognises the coin settle it. That keeps the guarantee exactly as it
     * was — a basket can only bind a coin that actually pays it — while sparing the factory, the
     * builder and the creator a question none of them are better placed to answer than the chain is.
     */
    uint8 public launchpad;

    uint256 private _lock; // reentrancy. Manual, not OZ: clones have no constructor to initialise it.

    // ----------------------------------------------------------------- events

    event Initialized(address indexed owner, address indexed creator, address indexed quote, uint32 interval);
    event Bound(address indexed coin, uint256 minHolderBalance);
    event Harvested(uint256 amount, uint256 platformFee, uint256 creatorShare);
    event CreatorClaimed(address indexed to, uint256 amount);
    event CreatorTransferred(address indexed previous, address indexed current);
    event Swapped(address indexed sellToken, uint256 spent, address indexed buyToken, uint256 bought);
    event Allocated(uint256 indexed basketIdx, uint256 amount, uint256 total);
    event Burned(address indexed coin, uint256 amount);
    event Distributed(uint256 indexed basketIdx, address indexed token, uint256 amount, uint256 holders);
    event ExcludedSet(address indexed account, bool value);
    event MinHolderBalanceSet(uint256 value);
    event OwnerChanged(address indexed previous, address indexed current);
    event PausedSet(bool value);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ------------------------------------------------------------------ errors

    error AlreadyInitialized();
    error NotOwner();
    error NotCreator();
    error NotKeeper();
    error Paused();
    error Reentrancy();
    error AlreadyBound();
    error NotFeeRecipient();
    /// The coin's fees are split across several wallets. This treasury takes a whole stream or
    /// none, so the creator has to reduce the split to one recipient before it can bind.
    error SplitNotWhole(uint256 recipients);
    /// The coin pays in an asset this basket does not measure. See the check in `bind`.
    error QuoteMismatch(address pairedAsset, address quote);
    error NotBound();
    error BadConfig();
    /// The basket holds the quote asset: there is nothing to swap, so it is allocated instead.
    error AllocateInstead();
    error NotInBasket();
    error BadSellToken();
    error ExceedsAvailable(uint256 wanted, uint256 available);
    error Overspent(uint256 spent, uint256 declared);
    error RouterCallFailed();
    /// The keeper named a venue the factory has not allowlisted (or has revoked).
    error VenueNotAllowed(address venue);
    error InsufficientOutput(uint256 got, uint256 wanted);
    error TooSoon(uint256 readyAt);
    error NothingToDistribute();
    /// `burn()` with no coin to destroy — a burn condition, not a distribution one.
    error NothingToBurn();
    error NothingToClaim();
    error NoEligibleHolders();
    error UnsortedHolders();
    error RoundOverspent();
    error NotAContract();
    error ProtectedAsset();
    error TransferFailed();

    // ---------------------------------------------------------------- modifiers

    /**
     * `owner` is kept for the identity it records, not for any power it carries.
     *
     * It names the wallet a treasury was created for — the site keys its dashboards off it, and
     * `IndexCreated` publishes it. It gates nothing: every administrative call on this contract is
     * the keeper's. A creator points their launch's fees here and that is the whole of their
     * involvement; nothing they can sign afterwards reaches the treasury, its configuration or its
     * balances. The modifier that used to enforce it is gone rather than left unused, so nobody
     * reintroduces a creator power by reaching for one that is already written.
     */
    modifier onlyKeeper() {
        if (!IIndexFactory(factory).keeper(msg.sender)) revert NotKeeper();
        _;
    }

    modifier nonReentrant() {
        if (_lock == 1) revert Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    modifier notPaused() {
        if (paused) revert Paused();
        _;
    }

    /// Locks the implementation itself: only clones (whose storage starts empty) can initialise.
    constructor() {
        factory = address(this);
    }

    // ------------------------------------------------------------ initialisation

    /// Called once by the factory right after cloning. `coin` is NOT set here: for a coin that has not
    /// launched yet the treasury has to exist first (its address goes in the launch as
    /// `creatorFeeRecipient`), so binding happens after — atomically from the factory when the coin
    /// already exists, via `bind()` otherwise.
    function initialize(
        address owner_,
        address creator_,
        address quote_,
        address[] calldata basket_,
        uint16[] calldata weights_,
        uint32 interval_,
        uint16 creatorShareBps_,
        uint8 mode_
    ) external {
        if (factory != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert BadConfig();
        if (mode_ > MODE_BUYBACK_BURN) revert BadConfig();
        /**
         * A buyback treasury has no basket to configure: what it buys is fixed by `bind()`, because
         * it is the coin. Requiring the arrays to be EMPTY rather than ignoring them is the
         * difference between a wizard bug that reverts and one that quietly deploys a treasury
         * holding a basket nobody will ever buy.
         */
        if (mode_ == MODE_BUYBACK_BURN) {
            if (basket_.length != 0 || weights_.length != 0) revert BadConfig();
        } else if (basket_.length == 0 || basket_.length != weights_.length) {
            revert BadConfig();
        }
        if (interval_ < MIN_INTERVAL || interval_ > MAX_INTERVAL) revert BadConfig();
        if (creatorShareBps_ > 10_000) revert BadConfig();

        // A basket MAY hold the asset its fees arrive in — a coin paired against NVDA whose creator
        // wants NVDA is the ordinary case, not an exotic one — and that entry is accounted through
        // `allocatedQuote` rather than a balance, which is what keeps the creator's share and the
        // unspent fees out of a payout.
        //
        // Native quotes are the exception. There the working asset is ether and WETH at once, so a
        // WETH entry would be the same collision with two balances to reconcile instead of one, for
        // a basket nobody has asked for. Duplicates stay out regardless: one token with two round
        // gates over one balance pays twice.
        address wethNow = IIndexFactory(msg.sender).weth();
        uint256 sum;
        for (uint256 i; i < basket_.length; ++i) {
            address t = basket_[i];
            if (t == address(0) || t.code.length == 0) revert BadConfig();
            if (quote_ == address(0) && t == wethNow) revert BadConfig();
            for (uint256 j; j < i; ++j) {
                if (basket_[j] == t) revert BadConfig();
            }
            sum += weights_[i];
            basket.push(t);
            weights.push(weights_[i]);
        }
        if (mode_ != MODE_BUYBACK_BURN && sum != 10_000) revert BadConfig();

        factory = msg.sender;
        owner = owner_;
        creator = creator_ == address(0) ? owner_ : creator_;
        quote = quote_;
        interval = interval_;
        creatorShareBps = creatorShareBps_;
        mode = mode_;

        minDistribution = 1; // no floor by default; the keeper gates on ETH value before buying
        batchWindow = interval_ / 3; // time to close an already-open round across several txs

        excluded[address(this)] = true;
        excluded[address(0)] = true;
        excluded[0x000000000000000000000000000000000000dEaD] = true;

        emit Initialized(owner_, creator, quote_, interval_);
    }

    // ------------------------------------------------------------------- bind

    /// Ties the launch token, once and irreversibly — and only the token whose creator fees actually
    /// arrive here.
    ///
    /// WHO MAY CALL THIS, AND WHY IT IS NOT ANYONE. The predicate proves the launchpad pays this
    /// treasury, and for the launch path that predicate is the coin's creator SPLIT — a value the
    /// coin's own creator writes freely. So anybody can launch a junk coin, point its split at
    /// somebody else's unbound treasury and bind it there: `coin` is write-once, the composition is
    /// immutable, and there is no unbind, so one cheap transaction would brick a stranger's treasury
    /// permanently and repeatably, against a target list this factory publishes itself.
    ///
    /// An earlier version of this contract left the call open, and was right to: it proved the
    /// `tokenCreator` role, which no attacker can point at a victim. The predicate moved; the caller
    /// check has to move with it.
    ///
    /// THE OWNER IS NOT ON THE LIST, and that is deliberate. `coin` is what the payout denominator is
    /// read over, so whoever picks it picks who gets paid: an owner able to bind could launch a coin
    /// it holds entirely, bind THAT instead of the one whose fees were pointed here, and then take
    /// every round while the real holders snapshot to zero. The fees still arrive — `collectAll` is
    /// permissionless and the watermark counts them however they land — so the substitution is
    /// invisible until the payouts go somewhere else. Factory covers the wizard (it carries the coin
    /// explicitly) and the keeper covers repair; the owner never needs this call.
    ///
    /// Deliberately NOT a global registry of taken coins: a creator changing their basket has to
    /// create a new treasury (the composition is immutable) and point the split again.
    function bind(address coin_) external {
        // Ordered so that probing a bound treasury is told the truth rather than "not allowed".
        if (coin != address(0)) revert AlreadyBound();
        if (msg.sender != factory && !IIndexFactory(factory).keeper(msg.sender)) revert NotKeeper();
        if (coin_ == address(0) || coin_.code.length == 0) revert BadConfig();

        /**
         * Ask each registered launchpad in turn and let the one that recognises the coin settle it.
         *
         * The guarantee is the same whoever answers, and so is the question: does this coin actually
         * pay this treasury? Only the registry differs, and every one of them has to answer as a VIEW
         * — which is the whole reason a launchpad can be added without being trusted with anything.
         *
         * A disabled launchpad is skipped, so a launchpad can be closed to NEW baskets without
         * stranding the ones already collecting from it.
         */
        uint8[] memory ids = IIndexFactory(factory).launchpadList();
        uint8 pad;
        address registry;
        uint8 kind;
        bool matched;
        uint256 spread;
        for (uint256 i; i < ids.length && !matched; ++i) {
            (address reg, uint8 k, bool on) = IIndexFactory(factory).launchpads(ids[i]);
            if (!on || reg == address(0)) continue;
            (address paid, bool permanent, uint256 splits) = _feeRecipientOf(k, reg, coin_);
            if (paid != address(this)) {
                // Remember WHY, so a refusal can tell the creator what to change instead of just
                // saying the coin is not theirs.
                if (splits > 1) spread = splits;
                continue;
            }
            bindIsPermanent = permanent;
            pad = ids[i];
            registry = reg;
            kind = k;
            matched = true;
        }
        if (!matched) {
            if (spread > 1) revert SplitNotWhole(spread);
            revert NotFeeRecipient();
        }

        /**
         * A coin a registry knows but holds no position for would harvest nothing forever: the
         * collect reverts, the best-effort call swallows it, and every round reports an ordinary
         * empty harvest. Refused here instead, while there is still somebody reading the revert.
         */
        if (!_collectable(kind, registry, coin_)) revert NotFeeRecipient();

        /**
         * What the launchpad will pay has to be what this treasury can measure.
         *
         * The paired leg arrives in the asset the coin was launched against, as an ERC20. A basket
         * quoted in anything else sees a delta of zero on every harvest: the fees land, and neither
         * the platform fee nor the creator's share is ever taken off them. That is an accounting hole
         * that reports itself as an ordinary empty round, so it is refused here, loudly.
         *
         * Native is the single exception, and only against WETH — there ether and wrapped are one
         * asset, `harvest` unwraps what the claim brings in, and quoting native is what keeps the
         * ETH-routed venues reachable.
         *
         * It is checked at bind and not at `initialize` because the launchpad is not known until this
         * call: the quote is chosen while the coin may not even exist yet.
         */
        address pairedAsset = _quoteOf(kind, registry, coin_);
        bool quoteFits = pairedAsset == IIndexFactory(factory).weth()
            ? (quote == address(0) || quote == pairedAsset)
            : quote == pairedAsset;
        if (!quoteFits) revert QuoteMismatch(pairedAsset, quote);

        /**
         * A basket may not hold the coin it collects for. It would make the treasury a holder of its
         * own launch, and it puts equity bought FOR holders in the same balance the burn path reads.
         * Checked here rather than in `initialize` because the coin is not known until this call.
         */
        uint256 n = basket.length;
        for (uint256 i; i < n; ++i) {
            if (basket[i] == coin_) revert BadConfig();
        }

        launchpad = pad;
        coin = coin_;
        excluded[coin_] = true;
        minHolderBalance = MIN_HOLDER_COINS * (10 ** _decimals(coin_));
        emit Bound(coin_, minHolderBalance);
    }

    /**
     * Who a launchpad actually PAYS for a coin — which is not the same question as who it calls the
     * creator, and getting that wrong is what made the first version of this contract unbindable.
     *
     * The locker consults the split first and falls back to the creator role only when there is no
     * split (`_payCreator`). So the effective recipient is:
     *
     *   split set        -> the split's sole 100% recipient, if there is exactly one
     *   no split         -> the creator role
     *
     * `permanent` distinguishes the two for the caller, because they carry very different promises:
     * a launch that named this treasury as its `feeRecipient` is a SPLIT, and the launching wallet
     * can repoint it whenever it likes. Only the role is beyond its reach.
     *
     * A staticcall rather than a typed call: a registry that does not recognise the coin — or one
     * day holds no code at all — should leave `bind` free to ask the next launchpad, not blow up the
     * whole loop.
     */
    function _feeRecipientOf(uint8 kind, address registry, address coin_)
        private
        view
        returns (address recipient, bool permanent, uint256 splitCount)
    {
        if (kind != KIND_CREATOR_LOCKER) return (address(0), false, 0);

        (bool ok, bytes memory ret) =
            registry.staticcall(abi.encodeWithSelector(IStonkFeeLocker.splitsOf.selector, coin_));
        if (ok && ret.length >= 64) {
            Split[] memory sp = abi.decode(ret, (Split[]));
            // Anything other than one recipient taking the whole stream is a configuration this
            // treasury cannot account for: it would be paid a fraction while reporting a whole.
            if (sp.length == 1 && sp[0].bps == 10_000) return (sp[0].to, false, 1);
            // Reported rather than reverted: this is a view, and `bind` turns it into an error the
            // creator can act on. A helper that threw would take `feeRecipientNow` down with it.
            if (sp.length != 0) return (address(0), false, sp.length);
        }

        (ok, ret) = registry.staticcall(abi.encodeWithSelector(IStonkFeeLocker.tokenCreator.selector, coin_));
        if (!ok || ret.length < 32) return (address(0), false, 0);
        return (abi.decode(ret, (address)), true, 0);
    }

    /// The asset the paired leg of a coin's fees arrives in.
    function _quoteOf(uint8 kind, address registry, address coin_) private view returns (address) {
        if (kind == KIND_CREATOR_LOCKER) {
            (bool ok, bytes memory ret) =
                registry.staticcall(abi.encodeWithSelector(IStonkFeeLocker.tokenQuote.selector, coin_));
            if (!ok || ret.length < 32) return address(0);
            return abi.decode(ret, (address));
        }
        return address(0);
    }

    /// Is there anything for this coin to collect FROM — a live fee position, not a live balance?
    function _collectable(uint8 kind, address registry, address coin_) private view returns (bool) {
        if (kind == KIND_CREATOR_LOCKER) {
            (bool ok, bytes memory ret) =
                registry.staticcall(abi.encodeWithSelector(IStonkFeeLocker.positionsOf.selector, coin_));
            if (!ok || ret.length < 64) return false;
            return abi.decode(ret, (uint256[])).length != 0;
        }
        return false;
    }

    /**
     * Who the launchpad would pay for this coin RIGHT NOW, and whether that is beyond the creator's
     * reach.
     *
     * `bindIsPermanent` is a snapshot taken at bind and never revised, because nothing on this
     * contract is called when a split changes on the locker. This re-derives it live, so the keeper
     * can stop cranking a treasury whose stream has been pointed away and the site can stop telling
     * holders a programme is running when it is not.
     *
     * Returns the zero address when the treasury is unbound, when no launchpad recognises the coin,
     * or when the split has been spread across several wallets.
     */
    function feeRecipientNow() external view returns (address recipient, bool permanent) {
        if (coin == address(0)) return (address(0), false);
        (address registry, uint8 kind,) = IIndexFactory(factory).launchpads(launchpad);
        if (registry == address(0)) return (address(0), false);
        (recipient, permanent,) = _feeRecipientOf(kind, registry, coin);
    }

    /// Missing/odd `decimals()` falls back to 18 rather than bricking the bind.
    function _decimals(address token) private view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && ret.length >= 32) {
            uint256 d = abi.decode(ret, (uint256));
            // the guard is the check: anything above 27 decimals is rejected outright, so the cast
            // cannot truncate — and 10**28 coins would overflow the floor anyway
            // forge-lint: disable-next-line(unsafe-typecast)
            if (d <= 27) return uint8(d);
        }
        return 18;
    }

    // ---------------------------------------------------------------- harvest

    /// Pulls the creator fees from pons' fee manager and splits them: the platform fee off the top,
    /// then the creator's share of the rest. What is left is the holders' — it can only leave this
    /// contract as stock, through a distribution.
    ///
    /// Permissionless: it only moves money IN. A platform-fee recipient that reverts is skipped rather
    /// than allowed to freeze everyone's fees.
    function harvest() external nonReentrant notPaused returns (uint256 received) {
        bool native = quote == address(0);
        // Party pays part of its fees in the launched coin. Measured across the claim so only what
        // this harvest brought in is burned — anything the basket may hold for other reasons is not
        // this function's to destroy.
        uint256 coinBefore = coin == address(0) ? 0 : IERC20(coin).balanceOf(address(this));
        /**
         * Party settles the paired leg as an ERC20 — WETH included, because the locker never sends
         * ether. Measured across the claim for the same reason the coin side is: only what this
         * harvest brings in wrapped is this function's to unwrap. pons pays a native quote in ether
         * and never reaches this, so the read costs the pons path nothing.
         */
        /**
         * The locker settles the paired leg as an ERC20 — WETH included, because it never sends
         * ether. Measured across the claim for the same reason the coin side is: only what this
         * harvest brings in wrapped is this function's to unwrap.
         */

        (address registry, uint8 kind,) = IIndexFactory(factory).launchpads(launchpad);
        _collect(kind, registry, native ? IIndexFactory(factory).weth() : quote);

        /**
         * Then make the paired leg the asset this treasury actually measures.
         *
         * The locker pays WETH for an ETH-quoted launch and never sends ether at all, so a
         * native-quoted basket has to unwrap or it cannot pay anything out in the asset it promised
         * — the platform fee and the creator's claim both settle in ether.
         *
         * ALL of it, not just what this collect brought in. The watermark counts ether and WETH as
         * one balance, so a delta-based unwrap would leave money that `received` has already been
         * split against sitting in the wrong form, and the fee payment would fail for want of ether
         * while the books said it was there. Nothing parks WETH deliberately — `_swap` wraps only
         * what a swap consumes — so a balance here is a partial fill's tail, not a position.
         */
        if (native) {
            address wethNow = IIndexFactory(factory).weth();
            uint256 wrapped = IERC20(wethNow).balanceOf(address(this));
            if (wrapped != 0) IWETH(wethNow).withdraw(wrapped);
        }

        // The coin side is burned rather than kept. A treasury that buys stock has no use for the
        // coin it is paid in, and holding it would make the basket a holder of its own launch.
        if (coin != address(0)) {
            uint256 coinFees = IERC20(coin).balanceOf(address(this)) - coinBefore;
            if (coinFees != 0 && _push(coin, BURN, coinFees)) emit Burned(coin, coinFees);
        }

        // Everything unaccounted, not just what THIS call brought in — see `accountedQuote`.
        uint256 held = _quoteHeld(IIndexFactory(factory).weth());
        received = held > accountedQuote ? held - accountedQuote : 0;
        if (received == 0) {
            // Re-anchor on the way out. A watermark ABOVE the real balance would otherwise make the
            // treasury deaf to real income up to the drift, silently and for good; the floor in
            // `_deduct` keeps this from ever dropping below what is already promised.
            if (accountedQuote > held) accountedQuote = held;
            emit Harvested(0, 0, 0);
            return 0;
        }

        uint256 fee;
        uint16 feeBps = IIndexFactory(factory).platformFeeBps();
        if (feeBps != 0) {
            address to = IIndexFactory(factory).platformFeeRecipient();
            if (to != address(0)) {
                fee = (received * feeBps) / 10_000;
                if (fee != 0 && !_pay(to, fee)) fee = 0;
            }
        }

        uint256 share = ((received - fee) * creatorShareBps) / 10_000;
        if (share != 0) creatorClaimable += share; // held, not pushed: the creator claims when they want

        // The fee is the only part that LEFT; everything else is still here and is now accounted.
        accountedQuote = held - fee;

        emit Harvested(received, fee, share);
    }

    /**
     * Pull whatever a launchpad owes this treasury, in the shape that launchpad speaks.
     *
     * Every call here is best-effort, and deliberately so: each one reverts in the ORDINARY case —
     * nothing collected yet, nothing deferred — and letting that bubble up would make a routine empty
     * harvest look like a treasury fault and kill the keeper's round. The balance delta measured by
     * the caller is the source of truth either way, so nothing here needs to report success.
     *
     * A `kind` this implementation does not know collects nothing rather than reverting: a treasury
     * bound to a launchpad whose id was later repointed at a newer shape should go quiet and be
     * fixable, not brick.
     */
    function _collect(uint8 kind, address registry, address quoteToken) private {
        if (registry == address(0)) return;
        if (kind == KIND_CREATOR_LOCKER) {
            /**
             * Collect, then sweep what could not be delivered.
             *
             * `collectAll` moves the pools' earned fees into the locker's ledger AND pays them out in
             * the same call, which is the call a fee recipient wants — a treasury that only claimed
             * would collect whatever somebody else's crank happened to credit it, and for a coin
             * nobody cranks, nothing, forever.
             *
             * But that payout is best-effort by design: when a direct transfer fails the locker
             * credits `claimable` and carries on rather than reverting the whole collect. Those
             * balances are reachable only through `claim`, one asset at a time, and only by their
             * owner — which is why this contract calls it itself rather than delegating collection to
             * an adapter that would receive the funds instead.
             */
            bool ok;
            (ok,) = registry.call(abi.encodeWithSelector(IStonkFeeLocker.collectAll.selector, coin));
            (ok,) = registry.call(abi.encodeWithSelector(IStonkFeeLocker.claim.selector, quoteToken));
            (ok,) = registry.call(abi.encodeWithSelector(IStonkFeeLocker.claim.selector, coin));
            ok; // silence: nothing to decide on, the delta is what counts
        }
    }

    /// Pays the creator what has accrued. Anyone may call it — the destination is fixed.
    function claimCreator() external nonReentrant returns (uint256 amount) {
        amount = creatorClaimable;
        if (amount == 0) revert NothingToClaim();
        creatorClaimable = 0;

        if (quote == address(0)) {
            uint256 bal = address(this).balance;
            // a swap may have left the tail of a wrap behind: unwrap just enough to make them whole
            if (bal < amount) IWETH(IIndexFactory(factory).weth()).withdraw(amount - bal);
        }
        _deduct(amount);
        if (!_pay(creator, amount)) revert TransferFailed();
        emit CreatorClaimed(creator, amount);
    }

    /// Moves the fee stream to another wallet. Only the creator can do it — the owner cannot redirect
    /// someone else's revenue.
    function transferCreator(address to) external {
        if (msg.sender != creator) revert NotCreator();
        if (to == address(0)) revert BadConfig();
        emit CreatorTransferred(creator, to);
        creator = to;
    }

    // ------------------------------------------------------------------- swap

    /// One call to an allowlisted venue with the calldata that venue's own quote returned.
    ///
    /// The keeper picks the venue and builds the route the same way the launch form already does for
    /// its ETH dev-buys — 0x AllowanceHolder for a routed order, the Slipstream router that reaches
    /// the factory the live equity/USDC depth actually sits on, SwapRouter02 for Uniswap.
    ///
    /// WHY THE VENUE IS AN ARGUMENT. On Robinhood Chain this was resolved from Rialto's own registry,
    /// so nobody — the factory owner included — could point a swap somewhere of their choosing. Base
    /// publishes no such registry: there is nothing to resolve against, and a single stored router
    /// would be one owner's pick with no second opinion. An allowlist is the honest version of the
    /// same idea, and the one this project already uses for its zap legs: the owner decides what is
    /// reachable, the keeper decides which of those to use, and revoking a venue takes it away from
    /// every treasury at once without touching any of them.
    ///
    /// Enforced here regardless of venue: the bought token must be in the basket, the sold token must
    /// be the quote asset (so equity already bought can never be sold again), the real balance delta
    /// must cover `minBuyAmount` — and the quote actually spent is MEASURED against `sellAmount`, not
    /// taken on trust. That last part is what makes the creator's fence real: `sellAmount` is a
    /// number the keeper types, while the venue pulls whatever its calldata says, so declaring one
    /// amount and settling a larger one would otherwise drain the accrued share (and the allowance
    /// for it).
    ///
    /// Pass `sellToken == address(0)` to sell native ether, which is what a venue reached by value
    /// rather than by allowance expects.
    function swap(
        address venue,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 minBuyAmount,
        bytes calldata routerCalldata
    ) external nonReentrant notPaused onlyKeeper returns (uint256 bought) {
        if (!IIndexFactory(factory).venue(venue)) revert VenueNotAllowed(venue);
        return _swap(venue, sellToken, sellAmount, buyToken, minBuyAmount, routerCalldata);
    }

    /**
     * Destroys the coin this treasury holds.
     *
     * PERMISSIONLESS, unlike every other value-moving call here, and safely so: it has exactly one
     * destination, it cannot be pointed anywhere, and it can only ever destroy the coin — there is
     * no list to curate, no denominator to inflate and no fill to skew, which is the entire reason
     * `swap` and `distribute` had to be gated and this does not. Nobody gains by calling it at a
     * chosen moment, because burning changes no holder's share relative to any other's.
     *
     * The fence is the real invariant rather than the mode: burning is refused only if the coin is
     * a BASKET entry, which would make it equity bought for holders. A mode check looked equivalent
     * — `bind` already refuses a basket holding the coin — and was strictly worse, because it left
     * a distribute treasury no way to retry a fee-leg burn that failed. `harvest` burns that leg
     * best-effort, so a coin with a transfer restriction leaves it sitting here, and with the mode
     * check every exit was shut: burn refused it, rescue protects the coin, and no swap or payout
     * names it. It would have been frozen for good, including after the restriction was lifted.
     */
    function burn() external nonReentrant returns (uint256 amount) {
        if (coin == address(0)) revert NotBound();
        // Second lock on the door `bind` already shut: never destroy equity bought for holders.
        if (_inBasket(coin)) revert ProtectedAsset();
        amount = IERC20(coin).balanceOf(address(this));
        if (amount == 0) revert NothingToBurn();
        if (!_push(coin, BURN, amount)) revert RouterCallFailed();
        emit Burned(coin, amount);
    }

    /**
     * Sets aside quote asset for holders, for the basket entry that IS the quote asset.
     *
     * A launch paired against NVDA already holds NVDA the moment its fees arrive, so buying it would
     * mean selling it to itself and paying a spread to end up where it started. There is no trade to
     * protect and no fill to measure — only a promise to keep, which is why this moves a number
     * rather than calling a router.
     *
     * It can only ever reach what `swap()` could have spent: the creator's accrual and anything
     * already allocated are outside `_availableQuote`, so neither can be promised twice.
     */
    function allocate(uint256 basketIdx, uint256 amount)
        external
        nonReentrant
        notPaused
        onlyKeeper
        returns (uint256 total)
    {
        address token = basket[basketIdx];
        if (!_isSelf(token)) revert NotInBasket();
        if (amount == 0) revert BadConfig();

        uint256 available = _availableQuote(IIndexFactory(factory).weth());
        if (amount > available) revert ExceedsAvailable(amount, available);

        total = allocatedQuote + amount;
        allocatedQuote = total;
        emit Allocated(basketIdx, amount, total);
    }

    function _swap(
        address router,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 minBuyAmount,
        bytes calldata routerCalldata
    ) private returns (uint256 bought) {
        /**
         * What may be bought, and it is the whole difference between the two modes.
         *
         * A buyback treasury buys exactly one thing — the coin — and it is not in `basket`, because
         * a buyback has no basket. Every other guarantee below is untouched: the sold token is still
         * the quote, the fill is still measured against `minBuyAmount`, and the spend is still
         * measured against `sellAmount`.
         */
        if (mode == MODE_BUYBACK_BURN) {
            if (buyToken != coin || coin == address(0)) revert NotInBasket();
        } else if (!_inBasket(buyToken)) {
            revert NotInBasket();
        }
        // Buying the quote asset with the quote asset is a round trip through a spread. The entry is
        // real, but it is filled by allocate(), not by a router.
        if (_isSelf(buyToken)) revert AllocateInstead();
        if (sellAmount == 0 || minBuyAmount == 0) revert BadConfig();

        if (router == address(0) || router.code.length == 0) revert RouterCallFailed();
        address weth = IIndexFactory(factory).weth();

        // sell ONLY the quote asset. With a native quote both address(0) and WETH count, because
        // Rialto quotes in WETH and we wrap on the fly.
        if (quote == address(0)) {
            if (sellToken != address(0) && sellToken != weth) revert BadSellToken();
        } else {
            if (sellToken != quote) revert BadSellToken();
        }

        uint256 available = _availableQuote(weth);
        if (sellAmount > available) revert ExceedsAvailable(sellAmount, available);

        uint256 heldQuoteBefore = _quoteHeld(weth);

        uint256 value;
        if (sellToken == address(0)) {
            if (sellAmount > address(this).balance) revert ExceedsAvailable(sellAmount, address(this).balance);
            value = sellAmount; // native sale: the router takes it as msg.value
        } else {
            if (sellToken == weth) {
                uint256 bal = IERC20(weth).balanceOf(address(this));
                if (bal < sellAmount) IWETH(weth).deposit{value: sellAmount - bal}();
            }
            // Rialto settles in allowance mode. Exactly what this swap declares, and revoked after:
            // an infinite standing approval would outlive the router the registry points at today.
            _approve(sellToken, router, sellAmount);
        }

        uint256 heldBefore = IERC20(buyToken).balanceOf(address(this));
        (bool ok,) = router.call{value: value}(routerCalldata);
        if (!ok) revert RouterCallFailed();
        if (sellToken != address(0)) _approve(sellToken, router, 0);

        bought = IERC20(buyToken).balanceOf(address(this)) - heldBefore;
        if (bought < minBuyAmount) revert InsufficientOutput(bought, minBuyAmount);

        uint256 spent = heldQuoteBefore - _quoteHeld(weth);
        if (spent > sellAmount) revert Overspent(spent, sellAmount);

        _deduct(spent);
        emit Swapped(sellToken, spent, buyToken, bought);
    }

    /// Everything this treasury holds in its quote asset, native and wrapped together.
    function _quoteHeld(address weth) private view returns (uint256) {
        return quote == address(0)
            ? address(this).balance + IERC20(weth).balanceOf(address(this))
            : IERC20(quote).balanceOf(address(this));
    }

    /// Quote asset that belongs to the holders — what the creator has accrued is not spendable.
    function _availableQuote(address weth) private view returns (uint256) {
        uint256 bal = _quoteHeld(weth);
        /**
         * Only money that has been THROUGH the split may be spent.
         *
         * Anything above the watermark still owes the platform fee and the creator's share, and the
         * locker's collect is permissionless — so quote can appear here without a harvest, and a
         * keeper that polls and spends would hand it whole to holders. Worse, spending it drove the
         * watermark under the creator's accrual, and the next harvest read that gap as fresh income
         * and charged both cuts a second time on money that had already paid them.
         */
        if (accountedQuote < bal) bal = accountedQuote;
        // Both are promised elsewhere: the creator's accrual, and anything already set aside for a
        // round. Neither may be spent buying stock.
        uint256 owed = creatorClaimable + allocatedQuote;
        return bal > owed ? bal - owed : 0;
    }

    /// Tolerates tokens that return nothing, and always writes through zero so tokens that refuse a
    /// non-zero-to-non-zero change still work.
    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        if (!(ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool)))))) revert TransferFailed();
        if (amount == 0) return;
        (ok, ret) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!(ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool)))))) revert TransferFailed();
    }

    // -------------------------------------------------------------- distribution

    /// Pushes one basket stock to the holders passed in, pro-rata on their coin balance.
    ///
    /// Weights are read from `balanceOf(coin)` in here: the caller picks WHO is included, never HOW
    /// MUCH. The list must be strictly ascending by address, which makes duplicates impossible — a
    /// repeated address would otherwise be counted and paid once per occurrence, letting the caller
    /// amplify its own weight while every individual balance read stayed honest.
    /// @dev A buyback treasury has nothing to distribute: what it buys is destroyed, not handed out.
    function distribute(uint256 basketIdx, address[] calldata holders)
        external
        nonReentrant
        notPaused
        onlyKeeper
        returns (uint256 sent)
    {
        address token = basket[basketIdx];
        return _distribute(basketIdx, token, _payable(token), holders, false);
    }

    /// Same, on a fixed slice of the balance: spreads one big distribution over several txs without
    /// skewing the weights. The keeper gives each batch its share of the global total.
    function distributeAmount(uint256 basketIdx, uint256 amount, address[] calldata holders)
        external
        nonReentrant
        notPaused
        onlyKeeper
        returns (uint256 sent)
    {
        address token = basket[basketIdx];
        if (amount > _payable(token)) revert NothingToDistribute();
        return _distribute(basketIdx, token, amount, holders, true);
    }

    function _distribute(
        uint256 basketIdx,
        address token,
        uint256 amount,
        address[] calldata holders,
        bool allowBatch
    ) private returns (uint256 sent) {
        if (coin == address(0)) revert NotBound();
        if (amount < minDistribution || amount == 0) revert NothingToDistribute();
        _gate(basketIdx, token, allowBatch);

        // Across every batch of one round, holders only ever move forward: batch N+1 must start above
        // where batch N stopped. Without it an honest keeper repeating a page boundary pays those
        // holders twice out of the next batch's slice, and the totals still look right.
        if (holders.length == 0) revert NoEligibleHolders();
        if (holders[0] <= roundCursor[basketIdx]) revert UnsortedHolders();

        uint256[] memory bals = new uint256[](holders.length);
        uint256 total = _snapshot(holders, bals);
        if (total == 0) revert NoEligibleHolders();

        uint256 paid = roundPaid[basketIdx] + amount;
        if (paid > roundBudget[basketIdx]) revert RoundOverspent();
        roundPaid[basketIdx] = paid;
        roundCursor[basketIdx] = holders[holders.length - 1];

        uint256 count;
        for (uint256 i; i < holders.length; ++i) {
            uint256 share = (amount * bals[i]) / total;
            if (share == 0) continue;
            if (_push(token, holders[i], share)) {
                sent += share;
                unchecked {
                    ++count;
                }
            }
        }

        // The ledger only ever falls by what actually moved, so a share that rounded to nothing stays
        // promised to holders rather than quietly returning to the spendable pot.
        // The quote-asset entry pays out in the quote itself, so it leaves the watermark too.
        if (sent != 0 && _isSelf(token)) {
            allocatedQuote -= sent;
            _deduct(sent);
        }

        emit Distributed(basketIdx, token, sent, count);
    }

    /// What a round may hand out for this entry: a tracked figure for the quote asset, a balance
    /// otherwise. The two must never be mixed — the balance also holds fees and the creator's share.
    function _payable(address token) private view returns (uint256) {
        return _isSelf(token) ? allocatedQuote : IERC20(token).balanceOf(address(this));
    }

    /// A round opens when the interval expires, and fixes the budget it may pay. Within `batchWindow`
    /// of that it can be continued in further txs (from distributeAmount only), to split a holder list
    /// too long for one tx. `distribute()` always opens a fresh round.
    function _gate(uint256 basketIdx, address token, bool allowBatch) private {
        uint256 start = lastDistribution[basketIdx];
        if (allowBatch && start != 0 && block.timestamp <= start + batchWindow) return;
        uint256 readyAt = start + interval;
        if (block.timestamp < readyAt) revert TooSoon(readyAt);
        lastDistribution[basketIdx] = block.timestamp;
        roundBudget[basketIdx] = _payable(token);
        roundPaid[basketIdx] = 0;
        roundCursor[basketIdx] = address(0);
    }

    /// Weights read on-chain: the caller picks WHO, never HOW MUCH. Holders under the dust line are
    /// skipped, so their slice goes to the rest instead of being spent on gas.
    function _snapshot(address[] calldata holders, uint256[] memory bals) private view returns (uint256 total) {
        address c = coin;
        uint256 floor = minHolderBalance;
        address prev;
        for (uint256 i; i < holders.length; ++i) {
            address h = holders[i];
            if (h <= prev) revert UnsortedHolders(); // strictly ascending ⇒ no duplicates, no zero
            prev = h;
            if (excluded[h]) continue;
            uint256 b = IERC20(c).balanceOf(h);
            if (b < floor) continue;
            bals[i] = b;
            total += b;
        }
    }

    /// A token that reverts on transfer would block everyone else: skip it.
    function _push(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    /// Pays `amount` of the quote asset, best-effort. Never reverts the caller.
    function _pay(address to, uint256 amount) private returns (bool) {
        if (quote == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            return ok;
        }
        return _push(quote, to, amount);
    }

    // ------------------------------------------------------------------ views

    function basketLength() external view returns (uint256) {
        return basket.length;
    }

    function basketAll() external view returns (address[] memory tokens, uint16[] memory bps) {
        return (basket, weights);
    }

    /// What is ready to distribute and from when — what the keeper polls.
    function pending(uint256 basketIdx) external view returns (uint256 amount, uint256 readyAt) {
        address token = basket[basketIdx];
        amount = _isSelf(token) ? allocatedQuote : IERC20(token).balanceOf(address(this));
        readyAt = lastDistribution[basketIdx] + interval;
    }

    /// Quote the keeper may spend on stock — net of what the creator has accrued.
    function spendableQuote() external view returns (uint256) {
        return _availableQuote(IIndexFactory(factory).weth());
    }

    /// The one entry, if any, that is the asset the fees arrive in. Allocated, never swapped.
    function _isSelf(address token) private view returns (bool) {
        return quote != address(0) && token == quote;
    }

    /// Quote left the contract: drop the watermark with it, clamped because a rounding tail must
    /// never make the next harvest think money arrived.
    function _deduct(uint256 amount) private {
        /**
         * Floored at what is still promised, never at zero.
         *
         * Everything owed to the creator or set aside for a round has already been split, so the
         * watermark may not fall below it: a lower mark is money the next harvest would treat as
         * newly arrived and charge for twice. Clamping at zero was enough to break the fence that
         * says a treasury always holds at least what it owes.
         */
        uint256 promised = creatorClaimable + allocatedQuote;
        uint256 next = accountedQuote > amount ? accountedQuote - amount : 0;
        accountedQuote = next > promised ? next : promised;
    }

    function _inBasket(address token) private view returns (bool) {
        uint256 n = basket.length;
        for (uint256 i; i < n; ++i) {
            if (basket[i] == token) return true;
        }
        return false;
    }

    // -------------------------------------------------------------- administration

    /// Exclusions are keeper-set, and can only ever name a CONTRACT.
    ///
    /// Both halves matter. The payout denominator is the sum of the non-excluded balances, so whoever
    /// controls this controls the split: an owner able to exclude the rest of the cap table would take
    /// the whole round with a single wallet, which is the same rug the keeper gate exists to prevent.
    /// Restricting it to contracts means no ordinary holder can be excluded by anyone — what this is
    /// actually for is the bonding curve, the pool and the like.
    function setExcluded(address account, bool value) external onlyKeeper {
        if (value && account.code.length == 0) revert NotAContract();
        excluded[account] = value;
        emit ExcludedSet(account, value);
    }

    function setExcludedBatch(address[] calldata accounts, bool value) external onlyKeeper {
        for (uint256 i; i < accounts.length; ++i) {
            if (value && accounts[i].code.length == 0) revert NotAContract();
            excluded[accounts[i]] = value;
            emit ExcludedSet(accounts[i], value);
        }
    }

    /// Keeper-set for the same reason as the exclusions: a floor above every holder's balance would
    /// freeze the payout, and one just under a single wallet's would hand it the round.
    function setMinHolderBalance(uint256 value) external onlyKeeper {
        minHolderBalance = value;
        emit MinHolderBalanceSet(value);
    }

    function setMinDistribution(uint256 value) external onlyKeeper {
        minDistribution = value;
    }

    /// Window to continue an already-open round. Must stay under the interval or rounds overlap.
    function setBatchWindow(uint32 value) external onlyKeeper {
        if (value >= interval) revert BadConfig();
        batchWindow = value;
    }

    function setPaused(bool value) external onlyKeeper {
        paused = value;
        emit PausedSet(value);
    }

    function transferOwnership(address to) external onlyKeeper {
        if (to == address(0)) revert BadConfig();
        emit OwnerChanged(owner, to);
        owner = to;
    }

    /// Recovers tokens that landed here by mistake. Basket stock and the quote asset are NOT
    /// recoverable: promising holders a payout and keeping a drain would be the rug this design exists
    /// to avoid. Bought stock leaves only as a distribution.
    function rescueERC20(address token, address to, uint256 amount) external onlyKeeper {
        /**
         * The coin is protected in EVERY mode, and the buyback is why.
         *
         * `_inBasket` used to be the whole guard, and a buyback treasury has no basket by
         * construction — so the coin it bought back with the holders' fees was fenced by nothing,
         * and the owner could front-run the permissionless burn and keep it. The same hole stood in
         * distribute mode over any coin the fee-leg burn failed to destroy.
         */
        if (_inBasket(token) || token == quote || token == coin) revert ProtectedAsset();
        if (quote == address(0) && token == IIndexFactory(factory).weth()) revert ProtectedAsset();
        if (!_push(token, to, amount)) revert TransferFailed();
        emit Rescued(token, to, amount);
    }

    /// Only on ERC20-quote treasuries, where native ETH is not the working asset.
    function rescueETH(address to, uint256 amount) external onlyKeeper {
        if (quote == address(0)) revert ProtectedAsset();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Rescued(address(0), to, amount);
    }

    receive() external payable {}
}
