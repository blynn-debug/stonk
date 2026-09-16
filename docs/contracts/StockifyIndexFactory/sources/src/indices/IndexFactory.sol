// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IIndexTreasury {
    function initialize(
        address owner_,
        address creator_,
        address quote_,
        address[] calldata basket_,
        uint16[] calldata weights_,
        uint32 interval_,
        uint16 creatorShareBps_,
        uint8 mode_
    ) external;
    function bind(address coin_) external;
}

/// ┌─────────────────────────────────────────────────────────────────────────────────────────────┐
/// │  IndexFactory — one treasury per Stonks launch, and the config they all share.              │
/// └─────────────────────────────────────────────────────────────────────────────────────────────┘
///
/// Mints EIP-1167 clones of IndexTreasury, each with its own basket and quote asset. Addresses are
/// deterministic (CREATE2 over a caller-chosen salt) because a treasury has to exist BEFORE the
/// launch that names it — and because it lets the site show a creator their address with no wallet
/// connected and nothing deployed yet.
///
/// Everything the clones need at runtime lives here and is read on every use, so if a locker is ever
/// superseded, or a second launchpad appears, the fix is one write and every live treasury keeps
/// working.
///
/// The clone implementation is NOT upgradeable. `setImplementation()` only affects FUTURE clones: a
/// creator who has already routed their fees here must never wake up to different logic underneath.
contract IndexFactory {
    // ---------------------------------------------------------------- storage

    address public owner;

    /**
     * Which generation of the service this is.
     *
     * Read on-chain rather than inferred from an address: when a later generation ships, a treasury
     * created under this one keeps the logic it was created with — clones are never upgraded — so
     * the only honest way to tell them apart is to ask them.
     */
    string public constant VERSION = "stockify-indices-1";

    address public implementation; // used by FUTURE clones only

    address public weth;

    /**
     * The launchpads a treasury may bind a coin from.
     *
     * A REGISTRY, not a constant. The two things a treasury needs from a launchpad are small and
     * stable — who it says a coin pays, and how that payment is collected — so a second one should
     * cost a transaction, not a new implementation and a migration for every creator who already
     * routed their fees. `kind` names the collection shape; `registry` is the contract that answers.
     *
     * Adding an id here cannot make a treasury execute anything of the owner's choosing: the shapes
     * live in the implementation's code and take no calldata from here. The worst a bad registry can
     * do is claim a coin pays a treasury that it does not — which binds a basket that harvests
     * nothing, and moves no money anywhere.
     */
    struct Launchpad {
        address registry; // the locker/launch record that answers for this launchpad
        uint8 kind; // which collection shape in IndexTreasury this registry speaks
        bool enabled; // bind() skips a disabled one; already-bound treasuries keep working
    }

    mapping(uint8 => Launchpad) public launchpads;
    uint8[] public launchpadIds; // insertion order — the order bind() asks in

    /**
     * Venues a treasury's `swap()` may be pointed at.
     *
     * An ALLOWLIST rather than a single stored router, because Base publishes no registry that names
     * the live venue the way Rialto does on Robinhood Chain — there is nothing to resolve against, so
     * a stored address would be the owner's choice with no second opinion. This is the same shape the
     * launcher already uses for its zap legs (`zap-targets.json`), and the same trust it already
     * carries: listing grants no approval and no custody, only the right to receive one trade's
     * input, still gated by that trade's own measured fill.
     *
     * Naming a venue per swap rather than storing "the" router also means a venue can be revoked
     * without touching a treasury, and a compromised one stops being reachable everywhere at once.
     */
    mapping(address => bool) public venue;

    /// Who may run the cycle on every treasury. A mapping, not an address: the service needs to
    /// rotate and to run a spare without redeploying anything.
    mapping(address => bool) public keeper;

    uint16 public platformFeeBps; // withheld on harvest, 0 = none
    address public platformFeeRecipient;

    address[] public allIndexes;
    mapping(address => address[]) public indexesOf; // creator => treasuries
    mapping(address => bool) public isIndex;

    /// What the site collects, in one call. `coin` may be zero: bind later, before pointing the fees.
    struct IndexConfig {
        address owner; // admin of the treasury: excludes, pause, rescue
        address creator; // receives creatorShareBps; zero = same as owner
        address quote; // asset the fees arrive in; address(0) = native ETH
        address[] basket;
        uint16[] weights; // bps, must sum to 10_000
        uint32 interval; // 15 minutes … 1 week
        uint16 creatorShareBps; // what the creator keeps of what reaches the treasury
        /// 0 = buy the basket and pay it to holders · 1 = buy the coin back and burn it. In buyback
        /// mode `basket` and `weights` must be empty: what it buys is the coin, fixed by the bind.
        uint8 mode;
        address coin; // already launched AND already pointed here? bind atomically. zero = bind later
    }

    // ----------------------------------------------------------------- events

    /// `deployer` is who paid for the create; `creator` is who the fee share actually accrues to.
    /// They differ the moment the site ever deploys on someone's behalf, and only the second is the
    /// one a dashboard should key on.
    event IndexCreated(
        address indexed treasury,
        address indexed deployer,
        address indexed owner,
        address creator,
        address coin,
        address quote,
        uint32 interval,
        uint16 creatorShareBps,
        uint8 mode,
        address implementation,
        address[] basket,
        uint16[] weights
    );
    event ImplementationSet(address indexed implementation);
    event ConfigSet(address weth);
    event LaunchpadSet(uint8 indexed id, address registry, uint8 kind, bool enabled);
    event VenueSet(address indexed venue, bool allowed);
    event KeeperSet(address indexed keeper, bool allowed);
    event PlatformFeeSet(uint16 bps, address recipient);
    event OwnerChanged(address indexed previous, address indexed current);

    // ------------------------------------------------------------------ errors

    error NotOwner();
    error BadConfig();
    error CloneFailed();
    error AddressMismatch(address got, address expected);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// Every address the clones will call must already hold code. A clone of a codeless
    /// implementation deploys and registers happily — the proxy has code, so the calls into it
    /// succeed as no-ops — leaving a treasury that looks live, can be named in a launch, and is
    /// permanently dead.
    function _requireContract(address a) private view {
        if (a == address(0) || a.code.length == 0) revert BadConfig();
    }

    constructor(address implementation_, address weth_) {
        _requireContract(implementation_);
        _requireContract(weth_);
        owner = msg.sender;
        implementation = implementation_;
        weth = weth_;
        emit ImplementationSet(implementation_);
        emit ConfigSet(weth_);
    }

    // ---------------------------------------------------------------- creation

    /// Creates the treasury, and binds the coin in the same tx when the locker already names it —
    /// which closes the only window in which somebody could bind the wrong token.
    ///
    /// `quote` is the asset the launch pays fees in: address(0) for native ETH, otherwise the token
    /// the coin is paired against (`feeLocker.tokenQuote(coin)`). That is the asset that gets sold to
    /// buy the basket, so a venue must be able to trade quote->stock; check it off-chain before
    /// creating, it cannot be checked here.
    ///
    /// `expected` is the address the creator was shown. Pass it: the CREATE2 address depends on the
    /// current implementation, so a `setImplementation` between "here is your address" and "deploy
    /// it" silently produces a different one — and the fees the launch already routed to the first
    /// address would be stranded at a contract that will never exist. Non-zero makes that mismatch
    /// revert.
    function createIndex(IndexConfig calldata cfg, bytes32 salt, address expected)
        external
        returns (address treasury)
    {
        treasury = _clone(implementation, keccak256(abi.encode(msg.sender, salt)));
        if (expected != address(0) && treasury != expected) revert AddressMismatch(treasury, expected);

        IIndexTreasury(treasury).initialize(
            cfg.owner,
            cfg.creator,
            cfg.quote,
            cfg.basket,
            cfg.weights,
            cfg.interval,
            cfg.creatorShareBps,
            cfg.mode
        );
        if (cfg.coin != address(0)) IIndexTreasury(treasury).bind(cfg.coin);

        allIndexes.push(treasury);
        indexesOf[msg.sender].push(treasury);
        isIndex[treasury] = true;

        emit IndexCreated(
            treasury,
            msg.sender,
            cfg.owner,
            cfg.creator == address(0) ? cfg.owner : cfg.creator,
            cfg.coin,
            cfg.quote,
            cfg.interval,
            cfg.creatorShareBps,
            cfg.mode,
            implementation,
            cfg.basket,
            cfg.weights
        );
    }

    /// The address `createIndex()` would produce for this creator and salt.
    function predictAddress(address creator, bytes32 salt) external view returns (address) {
        bytes32 s = keccak256(abi.encode(creator, salt));
        bytes32 h =
            keccak256(abi.encodePacked(bytes1(0xff), address(this), s, keccak256(_initCode(implementation))));
        return address(uint160(uint256(h)));
    }

    function indexCount() external view returns (uint256) {
        return allIndexes.length;
    }

    function indexCountOf(address creator) external view returns (uint256) {
        return indexesOf[creator].length;
    }

    /// Page over the registry — what the keeper walks on every cycle.
    function indexesPaged(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 n = allIndexes.length;
        if (offset >= n) return new address[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        page = new address[](end - offset);
        for (uint256 i; i < page.length; ++i) {
            page[i] = allIndexes[offset + i];
        }
    }

    // ------------------------------------------------------------------ EIP-1167

    function _initCode(address impl) private pure returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3"
        );
    }

    function _clone(address impl, bytes32 salt) private returns (address addr) {
        bytes memory code = _initCode(impl);
        assembly {
            addr := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (addr == address(0)) revert CloneFailed();
    }

    // -------------------------------------------------------------- administration

    /// Future clones only — see the header. Existing treasuries keep the logic they were created with.
    function setImplementation(address implementation_) external onlyOwner {
        _requireContract(implementation_);
        implementation = implementation_;
        emit ImplementationSet(implementation_);
    }

    /// Separate setters on purpose: coupling them means every WETH change is a chance to zero the fee
    /// locker, and a zero locker reverts `harvest()` on every live treasury at once.
    function setWeth(address weth_) external onlyOwner {
        _requireContract(weth_);
        weth = weth_;
        emit ConfigSet(weth_);
    }

    /// Register, repoint or disable a launchpad. Repointing an existing id moves every treasury bound
    /// to it at once — which is the point: a locker that is superseded is one write, not a migration.
    /// Disabling stops new binds and leaves bound treasuries harvesting, so a launchpad can be closed
    /// to new baskets without stranding the ones already collecting.
    function setLaunchpad(uint8 id, address registry, uint8 kind, bool enabled) external onlyOwner {
        if (enabled) _requireContract(registry);
        if (launchpads[id].registry == address(0) && registry != address(0)) launchpadIds.push(id);
        launchpads[id] = Launchpad({registry: registry, kind: kind, enabled: enabled});
        emit LaunchpadSet(id, registry, kind, enabled);
    }

    /// Every registered id, in the order `bind()` asks them.
    function launchpadList() external view returns (uint8[] memory) {
        return launchpadIds;
    }

    /// Allow or revoke a swap venue for every treasury at once. Revocation is immediate and needs no
    /// cooperation from a treasury, which is the point of keeping the list here rather than in each.
    function setVenue(address target, bool allowed) external onlyOwner {
        if (allowed) _requireContract(target);
        venue[target] = allowed;
        emit VenueSet(target, allowed);
    }

    function setKeeper(address account, bool allowed) external onlyOwner {
        keeper[account] = allowed;
        emit KeeperSet(account, allowed);
    }

    function setPlatformFee(uint16 bps, address recipient) external onlyOwner {
        if (bps > 2_000) revert BadConfig(); // hard cap 20%
        platformFeeBps = bps;
        platformFeeRecipient = recipient;
        emit PlatformFeeSet(bps, recipient);
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert BadConfig();
        emit OwnerChanged(owner, to);
        owner = to;
    }
}
