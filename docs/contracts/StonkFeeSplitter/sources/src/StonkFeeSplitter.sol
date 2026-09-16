// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWrappedNative} from "./interfaces/IV3.sol";

/// @dev The subset of StonkFeeLocker2 this contract cranks. `collectAll` is permissionless and
///      pushes a token's accrued platform fees to the locker's `feeRecipient` — which is this
///      splitter once the locker owner points it here.
interface IStonkLockerCrank {
    function collectAll(address token) external;
    function feeRecipient() external view returns (address);
}

/**
 * @title StonkFeeSplitter
 * @notice The platform's fee sink: it replaces the operator EOA as `feeRecipient` on the fee
 *         locker, then a keeper cranks and processes what arrives.
 *
 * @dev WHAT ARRIVES. The locker pays the platform's 0.3% cut per position in TWO tokens: the
 *      QUOTE side (WETH, or a B20 equity — the coin's "pair" asset) and the COIN side (the
 *      launchpad memecoin itself). So this contract accumulates WETH, a handful of equities, and
 *      one balance per launched coin.
 *
 * @dev THE ONE RULE, ENFORCED IN CODE: a launchpad memecoin is NEVER sold by the automation.
 *      Dumping a creator's coin is sell pressure on their project — the opposite of what this
 *      platform is. Only assets on the owner-curated `valueAsset` allowlist (WETH + the equities)
 *      can be swapped by the keeper, via `process`. A memecoin has no automated swap path at all;
 *      the sole way one can ever be sold is `sellViaVelora`, which is `onlyOwner` and exists as a
 *      manual escape hatch, not a routine.
 *
 * @dev THE SPLIT. Every fee asset is split the same way — 20% to the operator, 80% retained — but
 *      the 80% is handled by category:
 *        - VALUE assets (WETH + equities): 20% to the EOA in kind (WETH unwrapped to ETH), 80%
 *          swapped to $STONKEX via Velora and held forever (a buyback treasury).
 *        - MEMECOINS: 20% to the EOA in kind (the coin itself), 80% held in this contract,
 *          untouched.
 *
 * @dev NO DOUBLE-TAXING. The held 80% of each memecoin — and the bought $STONKEX — must not be
 *      taxed again when the next batch of the same token arrives. `retained[token]` records what
 *      is long-term held; only `balanceOf - retained` (the fresh arrivals) is ever processable.
 *
 * @dev VELORA. Swaps route through Velora (ParaSwap V6.2) Augustus at
 *      0x6A000F20005980200259B80c5102003040001068 on Base — where the approval target IS the
 *      Augustus itself. Kept as an owner-curated allowlist rather than hardcoded, so a future
 *      Augustus is a config change, not a redeploy. The keeper supplies the API-built calldata;
 *      this contract trusts the OUTCOME (a measured `buyToken` delta ≥ the keeper's floor), never
 *      the route, approves the EXACT input and resets the allowance to zero after every call.
 *
 * @dev POWERS. Owner (the operator EOA, Ownable2Step) curates the value-asset and Velora
 *      allowlists, the keeper set, the buy token, the profit receiver and split, and holds the
 *      full rescue surface (any ERC-20, ETH, or a total sweep) — which is also the migration path:
 *      to replace this splitter, the locker owner points `setFeeRecipient` at a new one and this
 *      contract is swept empty (`sweepMany` does it in one call). Renouncing is disabled — an
 *      ownerless sink holding fees would strand them.
 *
 * @dev KEEPER TRUST — READ THIS. The keeper is TRUSTED operator automation, not a low-trust
 *      role. It cannot sell a memecoin (no keeper path ever approves or transfers one) and
 *      cannot reach the held STONKEX treasury or the memecoin bags (never approved). But the
 *      value-asset buyback leg (`process`) runs a keeper-supplied Velora route bounded only by
 *      the keeper's own `minBuyOut` — a keeper that builds a route paying the bought token to
 *      itself is NOT stopped here. So a compromised keeper key can divert up to the buyback
 *      share of a single value-asset batch per call, until the owner revokes it with
 *      `setKeeper(k,false)`. Accepted trade-off for a fully automated buyback: run the keeper key
 *      with operator-level opsec. The escape hatch is on the locker — `setFeeRecipient` repoints
 *      fees away instantly.
 */
contract StonkFeeSplitter is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Wrapped native — the one value asset unwrapped to ETH for the profit leg.
    address public immutable WETH;

    /// @notice The token the 80% buyback acquires and holds ($STONKEX).
    address public buyToken;
    /// @notice Where the 20% profit is sent, in kind (the operator EOA).
    address public profitReceiver;
    /// @notice The fee locker this splitter cranks and receives from.
    address public locker;

    /// @notice Operator's share of every fee asset, in bps. The remainder is bought back / held.
    uint256 public profitBps = 2000;
    /// @notice Hard cap on the operator share — the creators/treasury always keep the majority.
    uint256 public constant MAX_PROFIT_BPS = 5000;

    /// @notice Automation wallets allowed to crank/process. The owner is always allowed too.
    mapping(address => bool) public keepers;
    /// @notice Pair assets (WETH + equities) the keeper may swap for the buyback. A token NOT on
    ///         this list can never be swapped by `process` — this is what protects the memecoins.
    mapping(address => bool) public valueAsset;
    /// @notice Allowlisted Velora Augustus targets (call + approval).
    mapping(address => bool) public veloraAllowed;

    /// @notice token => amount held long-term (bought $STONKEX + memecoin 80% bags), excluded from
    ///         any further profit-taking. Only `balanceOf(token) - retained[token]` is processable.
    mapping(address => uint256) public retained;

    event Collected(uint256 coins);
    event Processed(address indexed asset, uint256 amount, uint256 toOperator, uint256 spentOnBuyback, uint256 bought);
    event MemecoinSplit(address indexed asset, uint256 amount, uint256 toOperator, uint256 held);
    event Sold(address indexed token, uint256 amountIn, address indexed tokenOut, uint256 amountOut);
    event BuyTokenSet(address indexed buyToken);
    event ProfitReceiverSet(address indexed receiver);
    event LockerSet(address indexed locker);
    event ProfitBpsSet(uint256 bps);
    event KeeperSet(address indexed keeper, bool allowed);
    event ValueAssetSet(address indexed token, bool allowed);
    event VeloraTargetSet(address indexed target, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event RescuedEth(address indexed to, uint256 amount);

    error ZeroAddress();
    error AlreadyValueAsset();
    error NotKeeper();
    error NotValueAsset();
    error NotMemecoin();
    error TargetNotAllowed();
    error ProfitTooHigh();
    error NothingToProcess();
    error SwapFailed();
    error Slippage(uint256 got, uint256 min);
    error EthSendFailed();

    modifier onlyKeeper() {
        if (!keepers[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(
        address weth_,
        address buyToken_,
        address profitReceiver_,
        address locker_,
        address owner_
    ) Ownable(owner_) {
        if (
            weth_ == address(0) || buyToken_ == address(0) || profitReceiver_ == address(0)
                || locker_ == address(0) || owner_ == address(0)
        ) revert ZeroAddress();
        WETH = weth_;
        buyToken = buyToken_;
        profitReceiver = profitReceiver_;
        locker = locker_;
        keepers[owner_] = true;
    }

    // ------------------------------------------------------------------ crank

    /**
     * @notice Realize accrued fees into this contract by cranking the locker for each coin. Fees
     *         sit uncollected inside the Uniswap positions until someone calls `collectAll`; this
     *         batches that over a keeper-supplied list (read from `launcher.allTokens()` off-chain).
     * @dev Permissionless — it only ever pushes value TO this contract — and try/catch per coin so
     *      one token with no positions (or a transient revert) never bricks the whole round.
     */
    function collect(address[] calldata coins) external nonReentrant {
        IStonkLockerCrank l = IStonkLockerCrank(locker);
        for (uint256 i; i < coins.length; i++) {
            try l.collectAll(coins[i]) {} catch {}
        }
        emit Collected(coins.length);
    }

    // ------------------------------------------------------------------ process (value assets)

    /**
     * @notice Process one VALUE asset (WETH or an allowlisted equity): send 20% to the operator in
     *         kind (WETH → ETH), swap the other 80% to $STONKEX via Velora, and hold it.
     * @param asset       The value asset to process. MUST be on the `valueAsset` allowlist.
     * @param veloraTarget Allowlisted Augustus to call. MUST equal the approval target (V6.2 does).
     * @param veloraData  Velora API calldata swapping the 80% of `asset` into `buyToken`, delivered
     *                    to THIS contract.
     * @param minBuyOut   Floor on the $STONKEX received — the keeper's slippage protection.
     */
    function process(address asset, address veloraTarget, bytes calldata veloraData, uint256 minBuyOut)
        external
        onlyKeeper
        nonReentrant
        whenNotPaused
    {
        if (!valueAsset[asset]) revert NotValueAsset();
        if (!veloraAllowed[veloraTarget]) revert TargetNotAllowed();

        // Value assets are never held long-term (retained stays 0), but subtracting it keeps the
        // rule uniform and correct even if the owner ever changed a token's category.
        uint256 amt = IERC20(asset).balanceOf(address(this)) - retained[asset];
        if (amt == 0) revert NothingToProcess();

        uint256 profit = (amt * profitBps) / 10_000;
        uint256 buyAmt = amt - profit;

        if (profit > 0) {
            if (asset == WETH) {
                IWrappedNative(WETH).withdraw(profit);
                _sendEth(profitReceiver, profit);
            } else {
                IERC20(asset).safeTransfer(profitReceiver, profit);
            }
        }

        uint256 bought;
        if (buyAmt > 0) {
            uint256 beforeBal = IERC20(buyToken).balanceOf(address(this));
            IERC20(asset).forceApprove(veloraTarget, buyAmt);
            (bool ok,) = veloraTarget.call(veloraData);
            if (!ok) revert SwapFailed();
            IERC20(asset).forceApprove(veloraTarget, 0);
            bought = IERC20(buyToken).balanceOf(address(this)) - beforeBal;
            if (bought < minBuyOut) revert Slippage(bought, minBuyOut);
            retained[buyToken] += bought;
        }

        emit Processed(asset, amt, profit, buyAmt, bought);
    }

    // ------------------------------------------------------------------ process (memecoins)

    /**
     * @notice Process one launchpad MEMECOIN: send 20% to the operator in kind, hold the other 80%.
     *         No swap exists on this path — the coin is never sold here.
     * @dev Rejects the buy token and any value asset, so this can only ever touch a held-forever
     *      coin. `retained` grows by the 80%, so a later batch of the same coin taxes only the new
     *      arrivals, never the standing bag.
     */
    function processMemecoin(address asset) external onlyKeeper nonReentrant whenNotPaused {
        if (asset == buyToken || asset == WETH || valueAsset[asset]) revert NotMemecoin();

        uint256 amt = IERC20(asset).balanceOf(address(this)) - retained[asset];
        if (amt == 0) revert NothingToProcess();

        uint256 profit = (amt * profitBps) / 10_000;
        uint256 held = amt - profit;

        if (profit > 0) IERC20(asset).safeTransfer(profitReceiver, profit);
        retained[asset] += held;

        emit MemecoinSplit(asset, amt, profit, held);
    }

    // ------------------------------------------------------------------ owner-only emergency sell

    /**
     * @notice Owner-only escape hatch: liquidate a held token (a memecoin, or a stray asset)
     *         through Velora. Deliberately NOT on the keeper path — routine memecoin selling is
     *         exactly what this platform does not do; this is a manual, deliberate exception.
     * @dev Reduces `retained[token]` by what was sold so the accounting stays honest. The output
     *      stays in this contract (a value asset then flows through `process` next round).
     */
    function sellViaVelora(
        address token,
        uint256 amountIn,
        address veloraTarget,
        bytes calldata veloraData,
        address tokenOut,
        uint256 minOut
    ) external onlyOwner nonReentrant {
        if (!veloraAllowed[veloraTarget]) revert TargetNotAllowed();
        if (token == address(0) || tokenOut == address(0)) revert ZeroAddress();

        uint256 beforeBal = IERC20(tokenOut).balanceOf(address(this));
        IERC20(token).forceApprove(veloraTarget, amountIn);
        (bool ok,) = veloraTarget.call(veloraData);
        if (!ok) revert SwapFailed();
        IERC20(token).forceApprove(veloraTarget, 0);

        uint256 out = IERC20(tokenOut).balanceOf(address(this)) - beforeBal;
        if (out < minOut) revert Slippage(out, minOut);

        retained[token] = amountIn >= retained[token] ? 0 : retained[token] - amountIn;
        emit Sold(token, amountIn, tokenOut, out);
    }

    // ------------------------------------------------------------------ admin

    /// @notice Set the buyback token. Rejects a token currently on the value-asset allowlist —
    ///         mirroring `setValueAsset`'s reverse guard, so the two can never point at the same
    ///         token (which would let `process` "swap" it into itself and leave an un-retained,
    ///         re-taxable bag).
    function setBuyToken(address buyToken_) external onlyOwner {
        if (buyToken_ == address(0)) revert ZeroAddress();
        if (valueAsset[buyToken_]) revert AlreadyValueAsset();
        buyToken = buyToken_;
        emit BuyTokenSet(buyToken_);
    }

    function setProfitReceiver(address receiver_) external onlyOwner {
        if (receiver_ == address(0)) revert ZeroAddress();
        profitReceiver = receiver_;
        emit ProfitReceiverSet(receiver_);
    }

    function setLocker(address locker_) external onlyOwner {
        if (locker_ == address(0)) revert ZeroAddress();
        locker = locker_;
        emit LockerSet(locker_);
    }

    function setProfitBps(uint256 bps) external onlyOwner {
        if (bps > MAX_PROFIT_BPS) revert ProfitTooHigh();
        profitBps = bps;
        emit ProfitBpsSet(bps);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Add or remove a pair asset the keeper may swap for the buyback. The buy token can
    ///         never be a value asset (it would swap into itself).
    function setValueAsset(address token, bool allowed) external onlyOwner {
        if (token == address(0) || token == buyToken) revert ZeroAddress();
        valueAsset[token] = allowed;
        emit ValueAssetSet(token, allowed);
    }

    function setValueAssets(address[] calldata tokens, bool allowed) external onlyOwner {
        for (uint256 i; i < tokens.length; i++) {
            if (tokens[i] == address(0) || tokens[i] == buyToken) revert ZeroAddress();
            valueAsset[tokens[i]] = allowed;
            emit ValueAssetSet(tokens[i], allowed);
        }
    }

    function setVeloraTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        veloraAllowed[target] = allowed;
        emit VeloraTargetSet(target, allowed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Renouncing is disabled: this contract custodies platform fees and the buyback treasury,
    ///      and only the owner can move them or migrate to a new splitter.
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }

    // ------------------------------------------------------------------ rescue / migration

    /**
     * @notice Withdraw any ERC-20 — the migration and emergency path. Decrements `retained` so the
     *         no-double-tax accounting stays consistent with the real balance.
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        retained[token] = amount >= retained[token] ? 0 : retained[token] - amount;
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @notice Sweep an ERC-20's ENTIRE balance out (and clear its held accounting).
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        retained[token] = 0;
        IERC20(token).safeTransfer(to, bal);
        emit Rescued(token, to, bal);
    }

    /// @notice Sweep the ENTIRE balance of many tokens in one transaction — the emergency
    ///         migration path: after the locker owner repoints `setFeeRecipient` to a new splitter,
    ///         this evacuates every asset here (WETH, equities, $STONKEX, memecoins) at once. The
    ///         keeper supplies the full token list (`launcher.allTokens()` + WETH + equities +
    ///         $STONKEX). A zero-balance token is skipped rather than reverting the batch.
    function sweepMany(address[] calldata tokens, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        for (uint256 i; i < tokens.length; i++) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal == 0) continue;
            retained[tokens[i]] = 0;
            IERC20(tokens[i]).safeTransfer(to, bal);
            emit Rescued(tokens[i], to, bal);
        }
    }

    function rescueETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _sendEth(to, amount);
        emit RescuedEth(to, amount);
    }

    // ------------------------------------------------------------------ views

    /// @notice The amount of `token` a fresh `process`/`processMemecoin` would act on.
    function processable(address token) external view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 held = retained[token];
        return bal > held ? bal - held : 0;
    }

    // ------------------------------------------------------------------ internal

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert EthSendFailed();
    }

    /// @dev ETH arrives from unwrapping WETH on the profit leg and from any Velora route that pays
    ///      native. Accepted; never used to custody user funds across transactions.
    receive() external payable {}
}
