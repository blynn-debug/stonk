// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IV3Pool, IWrappedNative} from "./interfaces/IV3.sol";

interface IStonkLauncherInfo3 {
    function tokenInfo(address token)
        external
        view
        returns (
            address token_,
            address creator,
            address pool,
            address quote,
            uint256 tokenId,
            uint24 fee,
            uint256 createdAt
        );
}

/**
 * @title StonkTradeRouter3
 * @notice Buy and sell Stonks Exchange coins without depending on the frontend. Each coin trades on
 *         one 1% Uniswap V3 pool against its quote — a Base tokenized equity, or WETH — and the pool
 *         plus quote are read live from the launcher, so this router needs no registry of its own and
 *         can never disagree with what was actually launched.
 *
 * @dev V2 DELTA — THE ETH LEG IS VENUE-AGNOSTIC. V1 hardcoded Uniswap's SwapRouter02 for the
 *      ETH↔quote conversion, betting that equity liquidity would live on Uniswap. It has not landed
 *      anywhere yet, and the honest position is that nobody knows where it will. So V2 replaces the
 *      hardcoded router + path validation with an owner-curated allowlist of AGGREGATORS (0x, Odos,
 *      1inch, …): the caller supplies the aggregator and its API-built calldata, this contract
 *      verifies the OUTCOME — balance deltas against caller minimums — and never parses the route.
 *      Wherever the liquidity lands, the aggregators find it and nothing here redeploys.
 *
 *      What an allowlisted aggregator can and cannot do: it receives exactly the trade's own input
 *      (the attached ETH on a buy, an approval for exactly `quoteOut` on a sell), and if the
 *      required output does not materialize the whole trade reverts, unwinding the approval with
 *      it. A hostile listing can therefore fail trades, not take balances — and the direct
 *      `buy`/`sell` paths touch no aggregator at all.
 *
 * @dev The owner exists ONLY to curate that allowlist and rescue stray donations. Trading is
 *      permissionless and reads nothing the owner can influence; renouncing is disabled because an
 *      ownerless router could never list the next aggregator or delist a compromised one.
 *
 * @dev Nothing is custodied between transactions. Every function pulls, swaps and pays out
 *      atomically; the swap callback is gated on a transient `_activePool` so no third party can
 *      drive it to spend an allowance this contract holds.
 *
 * @dev V3 DELTA — AMOUNT-PATCHED SELLS. V2's `sellForETH` forwarded the quote→ETH calldata exactly
 *      as signed, but the amount that leg should spend — the pool leg's proceeds — only exists at
 *      execution time. So the signed calldata had to carry a conservative estimate, and whatever
 *      the pool paid above it came back to the seller as the quote asset: sell your whole balance
 *      "to ETH", receive a dusting of tokenized stock too. V3 closes it with the aggregator
 *      industry's standard move: the caller points at the byte offset where the leg's input amount
 *      lives, and this contract WRITES THE ACTUAL PROCEEDS into the calldata before the call. The
 *      second leg always spends 100% of what the first leg produced — zero dust, by construction —
 *      and the router stays venue-agnostic: it patches a number, it never parses a route.
 */
contract StonkTradeRouter3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice The launcher whose coins this router trades. Source of truth for pool + quote.
    IStonkLauncherInfo3 public immutable LAUNCHER;
    /// @notice Wrapped native.
    address public immutable WETH;

    /// @notice Aggregators the ETH legs may route through. Curated, never trusted with custody.
    mapping(address => bool) public zapTargets;

    uint160 private constant MIN_SQRT = 4295128739 + 1;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    address private _activePool;

    /// @dev Every entrypoint carries one. Aggregator calldata may embed its own deadline, but this
    ///      one covers the direct paths too — without it a signed trade can sit in the mempool
    ///      indefinitely and be included whenever it suits someone else.
    modifier notExpired(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    event Buy(address indexed buyer, address indexed token, address indexed quote, uint256 quoteIn, uint256 tokensOut);
    event Sell(address indexed seller, address indexed token, address indexed quote, uint256 tokensIn, uint256 quoteOut);
    event ZapTargetSet(address indexed target, bool allowed);

    error UnknownToken();
    error Expired();
    error Slippage();
    error ZeroAmount();
    error ZapTargetNotAllowed(address target);
    error ZapUnnecessary(); // WETH-quoted coins wrap/unwrap directly: no aggregator leg exists
    error ZapFailed();
    error ZapSlippage(uint256 got, uint256 min);
    error BadAmountOffset();
    error EthTransferFailed();

    constructor(address launcher_, address weth_, address owner_) Ownable(owner_) {
        require(launcher_ != address(0) && weth_ != address(0), "zero addr");
        LAUNCHER = IStonkLauncherInfo3(launcher_);
        WETH = weth_;
    }

    // ------------------------------------------------------------------ admin (allowlist only)

    /// @notice Curate the aggregator allowlist. Listing grants no approvals and no standing rights:
    ///         each trade approves at most its own amounts, inside its own transaction.
    function setZapTarget(address target, bool allowed) external onlyOwner {
        require(target != address(0), "target=0");
        zapTargets[target] = allowed;
        emit ZapTargetSet(target, allowed);
    }

    /// @dev Renouncing is disabled: an ownerless router could never replace a dead aggregator, and
    ///      the owner's only powers are the allowlist and donation rescue.
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }

    /// @notice Sweep a stray ERC-20 donation. The router holds nothing between transactions —
    ///         every trade refunds its own deltas — so this can only ever move accidents.
    function rescueToken(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "nothing");
        IERC20(token).safeTransfer(owner(), bal);
    }

    /// @notice Sweep stray ETH, same reasoning.
    function rescueEth() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "nothing");
        (bool ok,) = payable(owner()).call{value: bal}("");
        if (!ok) revert EthTransferFailed();
    }

    // ------------------------------------------------------------------ buy

    /// @notice Buy `token` by spending `quoteIn` raw units of its quote asset. Caller must have
    ///         approved this router for the quote (equities carry 8 decimals, WETH 18).
    function buy(address token, uint256 quoteIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        notExpired(deadline)
        returns (uint256 tokensOut)
    {
        if (quoteIn == 0) revert ZeroAmount();
        (address pool, address quote) = _poolAndQuote(token);
        IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteIn);
        return _buyWithQuote(token, pool, quote, quoteIn, minTokensOut);
    }

    /// @notice `buy` with the quote allowance authorized by an ERC-2612 signature in the same
    ///         transaction — B20 equities implement ERC-2612, so buying is one wallet action.
    function buyWithPermit(
        address token,
        uint256 quoteIn,
        uint256 minTokensOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant notExpired(deadline) returns (uint256 tokensOut) {
        if (quoteIn == 0) revert ZeroAmount();
        (address pool, address quote) = _poolAndQuote(token);
        // Best-effort: a signature already consumed (front-run, or a prior approve) must not brick
        // the buy — the transferFrom below is the real authorization check either way.
        try IERC20Permit(quote).permit(msg.sender, address(this), quoteIn, deadline, v, r, s) {} catch {}
        IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteIn);
        return _buyWithQuote(token, pool, quote, quoteIn, minTokensOut);
    }

    /**
     * @notice Buy `token` with ETH. For a WETH-quoted coin the attached ETH is simply wrapped; for
     *         an equity-quoted coin it is converted through `zapTarget` first.
     * @param zapTarget    Allowlisted aggregator for the ETH→quote leg. MUST be address(0) for a
     *                     WETH-quoted coin.
     * @param zapData      The aggregator's API-built calldata. Build it to deliver the quote to
     *                     THIS router and to refund unused ETH natively.
     * @param minQuoteOut  Floor on the first leg, so a bad route can't be sandwiched silently.
     * @param minTokensOut Floor on the coin received.
     */
    function buyWithETH(
        address token,
        address zapTarget,
        bytes calldata zapData,
        uint256 minQuoteOut,
        uint256 minTokensOut,
        uint256 deadline
    ) external payable nonReentrant notExpired(deadline) returns (uint256 tokensOut) {
        if (msg.value == 0) revert ZeroAmount();
        (address pool, address quote) = _poolAndQuote(token);

        uint256 quoteIn;
        if (quote == WETH) {
            if (zapTarget != address(0) || zapData.length != 0) revert ZapUnnecessary();
            IWrappedNative(WETH).deposit{value: msg.value}();
            quoteIn = msg.value;
        } else {
            if (!zapTargets[zapTarget]) revert ZapTargetNotAllowed(zapTarget);
            uint256 quoteBefore = IERC20(quote).balanceOf(address(this));
            uint256 balBefore = address(this).balance; // msg.value already credited
            (bool ok,) = zapTarget.call{value: msg.value}(zapData);
            if (!ok) revert ZapFailed();
            quoteIn = IERC20(quote).balanceOf(address(this)) - quoteBefore;
            if (quoteIn == 0 || quoteIn < minQuoteOut) revert ZapSlippage(quoteIn, minQuoteOut);
            // Return the aggregator's native refund (unused input) before the coin leg.
            uint256 ethBack = address(this).balance - (balBefore - msg.value);
            if (ethBack > 0) _sendEth(msg.sender, ethBack);
        }
        return _buyWithQuote(token, pool, quote, quoteIn, minTokensOut);
    }

    /// @dev Swap `quoteIn` (already held by this router) for the coin, paid straight to the caller.
    ///      Any quote the pool did not consume — possible only if the swap hits the band's price
    ///      limit — is returned rather than left behind.
    function _buyWithQuote(address token, address pool, address quote, uint256 quoteIn, uint256 minTokensOut)
        internal
        returns (uint256 tokensOut)
    {
        if (quoteIn == 0) revert ZeroAmount();
        bool zeroForOne = quote < token; // paying in quote
        uint256 balanceBefore = IERC20(token).balanceOf(msg.sender);

        _activePool = pool;
        (int256 a0, int256 a1) =
            IV3Pool(pool).swap(msg.sender, zeroForOne, quoteIn.toInt256(), zeroForOne ? MIN_SQRT : MAX_SQRT, "");
        _activePool = address(0);

        tokensOut = IERC20(token).balanceOf(msg.sender) - balanceBefore;
        if (tokensOut < minTokensOut) revert Slippage();

        // Refund only THIS trade's unspent input, computed from the swap deltas — never
        // address(this).balance, which would sweep a stray/donated router balance to the caller.
        uint256 spent = uint256(zeroForOne ? a0 : a1);
        if (spent < quoteIn) IERC20(quote).safeTransfer(msg.sender, quoteIn - spent);

        emit Buy(msg.sender, token, quote, spent, tokensOut);
    }

    // ------------------------------------------------------------------ sell

    /// @notice Sell `tokenAmount` of `token` for its quote asset. Caller must approve this router.
    function sell(address token, uint256 tokenAmount, uint256 minQuoteOut, uint256 deadline)
        external
        nonReentrant
        notExpired(deadline)
        returns (uint256 quoteOut)
    {
        (address pool, address quote) = _poolAndQuote(token);
        uint256 spent;
        (quoteOut, spent) = _sellToQuote(token, pool, quote, tokenAmount, msg.sender);
        if (quoteOut < minQuoteOut) revert Slippage();
        // `spent`, not `tokenAmount`: a band-edge sale can consume less than was offered, and an
        // indexer computing volume or price from this log must see what actually traded.
        emit Sell(msg.sender, token, quote, spent, quoteOut);
    }

    /**
     * @notice Sell `tokenAmount` of `token` and receive ETH, converting the quote back through an
     *         allowlisted aggregator (or a plain unwrap for WETH-quoted coins). The aggregator leg
     *         spends the ENTIRE proceeds: its input amount is patched into `zapData` at execution.
     * @param zapTarget       Allowlisted aggregator for the quote→ETH leg; address(0) for WETH quotes.
     * @param zapData         Aggregator calldata. Build it to deliver WETH to THIS router — WETH,
     *                        not native ETH, so delivery is uniform and measurable — with any
     *                        placeholder where the input amount goes; it is overwritten here.
     * @param amountInOffset  Byte offset in `zapData` of the 32-byte word holding the leg's input
     *                        amount. The actual pool proceeds are written there before the call.
     *                        Caller-controlled ON THE CALLER'S OWN calldata, so the worst a wrong
     *                        offset does is corrupt a route the caller chose — the approval stays
     *                        exactly the proceeds and `minEthOut` still gates the outcome.
     * @param minEthOut       Floor on the ETH the seller walks away with.
     */
    function sellForETH(
        address token,
        uint256 tokenAmount,
        address zapTarget,
        bytes calldata zapData,
        uint256 amountInOffset,
        uint256 minEthOut,
        uint256 deadline
    ) external nonReentrant notExpired(deadline) returns (uint256 ethOut) {
        (address pool, address quote) = _poolAndQuote(token);
        (uint256 quoteOut, uint256 spent) = _sellToQuote(token, pool, quote, tokenAmount, address(this));

        // A sale can legitimately consume nothing (selling into the empty side of the launch
        // band). Passing zero on would hand the aggregator a zero-input call whose behavior is
        // whatever its calldata says — some routers read zero as "use my whole balance". Stop here.
        if (quoteOut == 0) revert ZeroAmount();

        if (quote == WETH) {
            if (zapTarget != address(0) || zapData.length != 0) revert ZapUnnecessary();
            ethOut = quoteOut;
        } else {
            if (!zapTargets[zapTarget]) revert ZapTargetNotAllowed(zapTarget);
            // Patch the leg's input with the REAL proceeds. Past the selector, and whole-word:
            // a partial overwrite could splice two numbers into a third nobody chose.
            if (amountInOffset < 4 || amountInOffset + 32 > zapData.length) revert BadAmountOffset();
            bytes memory data = zapData;
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), amountInOffset), quoteOut)
            }

            uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
            IERC20(quote).forceApprove(zapTarget, quoteOut);
            (bool ok,) = zapTarget.call(data);
            if (!ok) revert ZapFailed();
            IERC20(quote).forceApprove(zapTarget, 0);
            ethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
            if (ethOut == 0) revert ZapSlippage(0, minEthOut);
            // The patch makes leftovers impossible on exact-input routes, but a route is caller
            // calldata — if one still leaves quote behind, it belongs to the seller.
            uint256 quoteLeft = IERC20(quote).balanceOf(address(this));
            if (quoteLeft > 0) IERC20(quote).safeTransfer(msg.sender, quoteLeft);
        }
        if (ethOut < minEthOut) revert Slippage();

        IWrappedNative(WETH).withdraw(ethOut);
        _sendEth(msg.sender, ethOut);

        // `quoteOut`, NOT `ethOut`: this is the same event and the same indexed `quote` topic that
        // `sell()` emits, so an indexer has no way to tell the two apart. Emitting wei here would
        // make every routed sale price ~1e9x wrong.
        emit Sell(msg.sender, token, quote, spent, quoteOut);
    }

    /// @dev Pull the coin, swap it for quote, deliver the quote to `recipient`. Any coin the pool
    ///      did not consume goes back to the seller. The pre-pull snapshot means a stray coin
    ///      balance donated to this router is never handed to whoever happens to trade next.
    function _sellToQuote(address token, address pool, address quote, uint256 tokenAmount, address recipient)
        internal
        returns (uint256 quoteOut, uint256 spent)
    {
        if (tokenAmount == 0) revert ZeroAmount();
        uint256 tokBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        bool zeroForOne = token < quote; // paying in the coin
        uint256 quoteBefore = IERC20(quote).balanceOf(recipient);

        _activePool = pool;
        (int256 a0, int256 a1) =
            IV3Pool(pool).swap(recipient, zeroForOne, tokenAmount.toInt256(), zeroForOne ? MIN_SQRT : MAX_SQRT, "");
        _activePool = address(0);

        quoteOut = IERC20(quote).balanceOf(recipient) - quoteBefore;
        spent = uint256(zeroForOne ? a0 : a1);

        uint256 leftover = IERC20(token).balanceOf(address(this)) - tokBefore;
        if (leftover > 0) IERC20(token).safeTransfer(msg.sender, leftover);
    }

    // ------------------------------------------------------------------ callback + views

    /// @dev V3 swap callback — pay the pool whichever token it is owed, from our balance. Gated on
    ///      the transient `_activePool`, so only a swap this contract itself initiated can reach it.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == _activePool && _activePool != address(0), "unauth cb");
        if (amount0Delta > 0) {
            IERC20(IV3Pool(msg.sender).token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IV3Pool(msg.sender).token1()).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }

    /// @notice The pool and quote asset a coin trades on, as recorded by the launcher.
    function poolAndQuote(address token) external view returns (address pool, address quote) {
        return _poolAndQuote(token);
    }

    function _poolAndQuote(address token) internal view returns (address pool, address quote) {
        (,, pool, quote,,,) = LAUNCHER.tokenInfo(token);
        // An unlaunched (or foreign) token reads back as the zero struct — reject it here rather
        // than letting a swap against address(0) produce an opaque failure.
        if (pool == address(0)) revert UnknownToken();
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev ETH arrives from the WETH contract on the unwrap path and from allowlisted aggregators
    ///      refunding a zap leg's unused input. Anything else is a mistake — reject it so it can
    ///      bounce instead of stranding.
    receive() external payable {
        require(msg.sender == WETH || zapTargets[msg.sender], "direct eth");
    }
}
