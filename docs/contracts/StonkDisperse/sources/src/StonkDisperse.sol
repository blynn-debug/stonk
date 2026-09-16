// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StonkDisperse
 * @notice Batch-push an ERC-20 to a list of recipients in one transaction, attributed to a named
 *         list. Built for KOL airdrops: a creator buys coin supply on the open market and pushes it
 *         to a curated cohort (the FOMO top traders), and an off-chain indexer scores what each
 *         recipient does with it afterwards.
 *
 * @dev DELIBERATELY THE SMALLEST POSSIBLE CONTRACT. No owner, no fees, no allowlist, no custody:
 *      tokens move straight from `msg.sender` to each recipient via `transferFrom`, so this
 *      contract never holds a balance and there is nothing here to rug, upgrade, or administer.
 *      It is the push half of a larger airdrop design; a future claim-based protocol (deadlines,
 *      claw-back, endorsement gating) will be a SEPARATE contract rather than options bolted onto
 *      this one — a sender who wants unconditional delivery should not have to trust code paths
 *      they never asked for.
 *
 * @dev WHY `listId` IS ON-CHAIN. The per-recipient amounts are already public — each transfer in
 *      the batch emits the token's own `Transfer` log in this same transaction — so the event here
 *      carries only what those logs cannot: WHICH curated list (and which version of it) this batch
 *      claimed to target. The indexer joins `Airdropped` to the tx's `Transfer` logs by tx hash and
 *      can then verify the recipients actually match the named list; a batch whose recipients
 *      diverge from its `listId` is visibly lying about who it paid.
 *
 * @dev ALL-OR-NOTHING BY DESIGN. One failing transfer reverts the whole batch. For the tokens this
 *      is built for (StonkToken: plain ERC-20, no hooks, no gates) a transfer cannot fail, so the
 *      simplicity costs nothing. For policy-gated tokens (B20 equities), a blocked recipient WILL
 *      revert the batch — that is the correct default for an airdrop ("everyone got it" or "nobody
 *      did"), and callers airdropping gated assets should pre-filter recipients against the gate
 *      (the quote registry exposes `canReceive` for exactly this kind of read).
 */
contract StonkDisperse {
    using SafeERC20 for IERC20;

    /// @notice One batch delivered. Recipients and per-recipient amounts live in this transaction's
    ///         `Transfer` logs; `listId` names the curated list (and version) the batch targeted.
    event Airdropped(
        address indexed token,
        address indexed sender,
        bytes32 indexed listId,
        uint256 recipients,
        uint256 totalAmount
    );

    error EmptyBatch();
    error LengthMismatch();
    error ZeroRecipient();
    error ZeroAmount();

    /**
     * @notice Send `amounts[i]` of `token` to `recipients[i]`, for every i, pulled from the caller.
     *         Caller must have approved this contract for the sum of `amounts`.
     * @param listId Identifier of the curated list this batch targets — by convention
     *        `keccak256(abi.encodePacked(listName, listVersion))`, but any caller-chosen tag works.
     *        Purely for off-chain attribution; nothing on-chain reads it back.
     */
    function disperse(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts,
        bytes32 listId
    ) external {
        uint256 n = recipients.length;
        if (n == 0) revert EmptyBatch();
        if (amounts.length != n) revert LengthMismatch();

        uint256 total;
        for (uint256 i; i < n; i++) {
            address to = recipients[i];
            uint256 amount = amounts[i];
            // A zero recipient burns nothing (most ERC-20s revert) but a zero AMOUNT would emit a
            // phantom Transfer log the indexer then books as an airdrop that paid nothing — reject
            // both so every row in the batch is a real delivery.
            if (to == address(0)) revert ZeroRecipient();
            if (amount == 0) revert ZeroAmount();
            total += amount;
            IERC20(token).safeTransferFrom(msg.sender, to, amount);
        }

        emit Airdropped(token, msg.sender, listId, n, total);
    }
}
