// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { ICoreStopGuardianV1 } from "./ICoreStopGuardianV1.sol";

import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { StopGuardianEnabled } from "../../libraries/DefinitiveErrors.sol";

abstract contract CoreStopGuardian is ICoreStopGuardianV1, Context {
    /// @custom:storage-location erc7201:definitive.storage.CoreStopGuardian
    struct CoreStopGuardianStorage {
        bool stopGuardianEnabled;
    }

    // keccak256(abi.encode(uint256(keccak256("definitive.storage.CoreStopGuardian")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CoreStopGuardianStorageLocation =
        0x6e256963d8788aaa49f4ac4e7631ab95aeec255e6d6477beec524cf8dfccec00;

    function _getCoreStopGuardianStorage() private pure returns (CoreStopGuardianStorage storage $) {
        assembly {
            $.slot := CoreStopGuardianStorageLocation
        }
    }

    // recommended for every public/external function
    modifier stopGuarded() {
        if (STOP_GUARDIAN_ENABLED()) {
            revert StopGuardianEnabled();
        }

        _;
    }

    function STOP_GUARDIAN_ENABLED() public view override returns (bool) {
        CoreStopGuardianStorage storage $ = _getCoreStopGuardianStorage();
        return $.stopGuardianEnabled;
    }

    function enableStopGuardian() public virtual;

    function disableStopGuardian() public virtual;

    function _enableStopGuardian() internal {
        CoreStopGuardianStorage storage $ = _getCoreStopGuardianStorage();

        $.stopGuardianEnabled = true;
        emit StopGuardianUpdate(_msgSender(), true);
    }

    function _disableStopGuardian() internal {
        CoreStopGuardianStorage storage $ = _getCoreStopGuardianStorage();

        $.stopGuardianEnabled = false;
        emit StopGuardianUpdate(_msgSender(), false);
    }
}
