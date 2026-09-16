// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IV3Pool} from "./interfaces/IV3.sol";

interface IStonkLauncherInfoQ {
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
 * @title StonkQuoter
 * @notice Exact-output quotes for Stonks Exchange coins, so the frontend can compute a real `minOut`
 *         before sending a trade. Mirrors `StonkTradeRouter`'s direct-pool exact-input swap.
 *
 * @dev Uses Uniswap's standard revert trick: run `pool.swap` and revert from the callback carrying the
 *      output amount — a pure simulation that changes no state and moves no funds. Call via `eth_call`
 *      / `staticcall`; the functions are non-view because the simulated swap is a state-mutating call
 *      shape even though it always unwinds.
 *
 * @dev Amounts are RAW units on both sides: the coin is 18-decimal, the quote is whatever its asset
 *      uses (8 for Base's tokenized equities, 18 for WETH). This quoter deliberately covers only the
 *      coin↔quote leg — for the ETH↔quote leg of `buyWithETH` / `sellForETH`, use Uniswap's own quoter
 *      or its routing API, which is the same source that produces the path.
 */
contract StonkQuoter {
    IStonkLauncherInfoQ public immutable LAUNCHER;

    uint160 private constant MIN_SQRT = 4295128739 + 1;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    /// @dev Prefix that marks a revert payload as one THIS contract's callback produced. See
    ///      `uniswapV3SwapCallback`.
    bytes32 private constant QUOTE_MAGIC = keccak256("StonkQuoter.quote.v1");

    error UnknownToken();
    error ZeroAmount();
    error BadQuote();

    constructor(address launcher_) {
        require(launcher_ != address(0), "zero addr");
        LAUNCHER = IStonkLauncherInfoQ(launcher_);
    }

    /// @notice Coin received for spending `quoteIn` raw units of the coin's quote asset.
    function quoteBuy(address token, uint256 quoteIn) external returns (uint256 tokensOut) {
        (address pool, address quote) = _poolAndQuote(token);
        return _simulate(pool, quoteIn, quote < token);
    }

    /// @notice Quote asset received for selling `tokenAmount` raw units of the coin.
    function quoteSell(address token, uint256 tokenAmount) external returns (uint256 quoteOut) {
        (address pool, address quote) = _poolAndQuote(token);
        return _simulate(pool, tokenAmount, token < quote);
    }

    function _simulate(address pool, uint256 amountIn, bool zeroForOne) private returns (uint256 out) {
        if (amountIn == 0) revert ZeroAmount();
        try IV3Pool(pool).swap(
            address(this),
            zeroForOne,
            SafeCast.toInt256(amountIn),
            zeroForOne ? MIN_SQRT : MAX_SQRT,
            abi.encode(zeroForOne)
        ) {
            revert BadQuote(); // unreachable — the callback always reverts with the amount
        } catch (bytes memory reason) {
            // Accept ONLY a payload our own callback produced. A bare 32-byte reason is not enough:
            // a V3 pool transfers the output token BEFORE invoking the callback, so a token with a
            // transfer hook could `revert(0, 32)` with a word of its choosing, propagate out of
            // `swap`, and dictate the amount this returns — without the callback ever running. The
            // magic prefix is the only part of that path an attacker cannot forge.
            if (reason.length != 64) revert BadQuote();
            (bytes32 magic, uint256 amount) = abi.decode(reason, (bytes32, uint256));
            if (magic != QUOTE_MAGIC) revert BadQuote();
            out = amount;
        }
    }

    /**
     * @dev The pool calls this mid-swap; we revert with the output amount instead of paying, which
     *      unwinds the whole simulated swap.
     *
     *      The payload is prefixed with `QUOTE_MAGIC` so `_simulate` can tell an answer from this
     *      callback apart from any other 32-byte revert raised inside the swap. Keeping the function
     *      `pure` also keeps `quoteBuy`/`quoteSell` reachable by `staticcall`, which an on-chain
     *      integrator may rely on.
     */
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external
        pure
    {
        bool zeroForOne = abi.decode(data, (bool));
        int256 outDelta = zeroForOne ? amount1Delta : amount0Delta;
        uint256 out = outDelta < 0 ? uint256(-outDelta) : 0;
        bytes32 magic = QUOTE_MAGIC;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, magic)
            mstore(add(p, 32), out)
            revert(p, 64)
        }
    }

    function _poolAndQuote(address token) private view returns (address pool, address quote) {
        (,, pool, quote,,,) = LAUNCHER.tokenInfo(token);
        if (pool == address(0)) revert UnknownToken();
    }
}
