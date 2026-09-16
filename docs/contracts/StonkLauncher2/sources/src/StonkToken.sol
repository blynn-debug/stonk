// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IStonkLauncherBaseURI {
    function baseTokenURI() external view returns (string memory);
}

/**
 * @title StonkToken
 * @notice The per-launch ERC-20: dead-plain, immutable, fixed supply, 18 decimals. No mint, no burn
 *         hooks, no pausing, no blacklist, no transfer gates of any kind — unrestricted transfers
 *         from block 0. The entire supply is minted to the launcher, which immediately places it as
 *         a single-sided full-range Uniswap V3 position locked in the fee locker.
 *
 * @dev Deliberately the OPPOSITE of the B20 equity it trades against: the quote side is
 *      policy-gated and issuer-controlled by design, the coin side is ungoverned by construction.
 *      Nothing here is upgradeable and no privileged address exists.
 */
contract StonkToken is ERC20 {
    address public immutable launcher;
    address public immutable creator;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address launcher_,
        address creator_
    ) ERC20(name_, symbol_) {
        require(totalSupply_ > 0, "supply=0");
        require(launcher_ != address(0), "launcher=0");
        launcher = launcher_;
        creator = creator_;
        _mint(launcher_, totalSupply_);
    }

    /// @notice Off-chain metadata pointer: `<launcher.baseTokenURI()><address>.json`. Reads the base
    ///         live from the launcher (one source shared by every coin) so the platform domain can be
    ///         rotated with a single owner call. Returns "" when unset or on any failure — never reverts.
    function tokenURI() external view returns (string memory) {
        try IStonkLauncherBaseURI(launcher).baseTokenURI() returns (string memory base) {
            if (bytes(base).length == 0) return "";
            return string.concat(base, _hexAddress(), ".json");
        } catch {
            return "";
        }
    }

    function _hexAddress() private view returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 a = bytes20(address(this));
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            s[2 + i * 2] = alphabet[uint8(a[i]) >> 4];
            s[3 + i * 2] = alphabet[uint8(a[i]) & 0x0f];
        }
        return string(s);
    }
}
