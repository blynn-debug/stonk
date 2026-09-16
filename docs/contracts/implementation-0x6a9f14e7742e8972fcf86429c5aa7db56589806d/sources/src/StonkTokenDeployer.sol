// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StonkToken} from "./StonkToken.sol";

/**
 * @title StonkTokenDeployer
 * @notice External (linked) library holding StonkToken's CREATE bytecode so it lives in a separately
 *         deployed, linked contract instead of embedded in StonkLauncher — keeping the launcher
 *         comfortably under the EIP-170 24,576-byte runtime limit.
 *
 * @dev `deployToken` is delegatecalled, so `address(this)` during CREATE2 is the launcher and
 *      deterministic token addresses match `predictToken` exactly. `predictToken` is `pure`, takes
 *      `launcher` explicitly (no delegatecall-context dependence) and the ALREADY-FINAL CREATE2
 *      `salt` — the SAME value the launcher passes to `deployToken` — so the salt-derivation formula
 *      lives solely in the launcher and predict==actual can never drift from two independent
 *      formulas. The two constructor-arg-order restatements that must stay mutually consistent both
 *      live in THIS file (`predictToken`'s abi.encode and `deployToken`'s `new` call).
 */
library StonkTokenDeployer {
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        address launcher,
        address creator,
        bytes32 salt
    ) external returns (address) {
        return address(new StonkToken{salt: salt}(name, symbol, totalSupply, launcher, creator));
    }

    function predictToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        address launcher,
        address creator,
        bytes32 salt
    ) external pure returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(StonkToken).creationCode, abi.encode(name, symbol, totalSupply, launcher, creator))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), launcher, salt, initHash)))));
    }
}
