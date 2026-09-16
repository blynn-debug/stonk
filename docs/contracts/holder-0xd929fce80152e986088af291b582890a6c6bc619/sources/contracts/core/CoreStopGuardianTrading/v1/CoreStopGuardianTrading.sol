// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { ICoreStopGuardianTradingV1 } from "./ICoreStopGuardianTradingV1.sol";

import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { WithdrawalsDisabled, TradingDisabled, GlobalStopGuardianEnabled } from "../../libraries/DefinitiveErrors.sol";
import { IGlobalGuardian } from "../../../tools/GlobalGuardian/IGlobalGuardian.sol";
import { CoreGlobalGuardian } from "../../CoreGlobalGuardian/CoreGlobalGuardian.sol";

abstract contract CoreStopGuardianTrading is ICoreStopGuardianTradingV1, Context, CoreGlobalGuardian {
    /// @custom:storage-location erc7201:definitive.storage.CoreStopGuardianTrading
    struct CoreStopGuardianTradingStorage {
        bool TRADING_GUARDIAN_TRADING_DISABLED;
        bool TRADING_GUARDIAN_WITHDRAWALS_DISABLED;
    }

    /* solhint-disable max-line-length */
    // keccak256(abi.encode(uint256(keccak256("definitive.storage.CoreStopGuardianTrading")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CoreStopGuardianTradingStorageLocation =
        0x16cbd83eaf0105ad9cb99491311ec69c270710363d0a5092df3b41a81f4a9400;

    /* solhint-enable max-line-length */

    function _getCoreStopGuardianTradingStorage() private pure returns (CoreStopGuardianTradingStorage storage $) {
        assembly {
            $.slot := CoreStopGuardianTradingStorageLocation
        }
    }

    /// 0x49feb0371fc9661748a3d1bc01dbf9f5cdeb4102767351e1c6dd1f5d331acd6d
    bytes32 internal constant GLOBAL_TRADING_HASH = keccak256("TRADING");

    modifier tradingEnabled() {
        CoreStopGuardianTradingStorage storage $ = _getCoreStopGuardianTradingStorage();

        if (IGlobalGuardian(GLOBAL_TRADE_GUARDIAN()).functionalityIsDisabled(GLOBAL_TRADING_HASH)) {
            revert GlobalStopGuardianEnabled();
        }

        if ($.TRADING_GUARDIAN_TRADING_DISABLED) {
            revert TradingDisabled();
        }
        _;
    }

    modifier withdrawalsEnabled() {
        CoreStopGuardianTradingStorage storage $ = _getCoreStopGuardianTradingStorage();

        if ($.TRADING_GUARDIAN_WITHDRAWALS_DISABLED) {
            revert WithdrawalsDisabled();
        }
        _;
    }

    function TRADING_GUARDIAN_TRADING_DISABLED() public view returns (bool) {
        CoreStopGuardianTradingStorage storage $ = _getCoreStopGuardianTradingStorage();
        return $.TRADING_GUARDIAN_TRADING_DISABLED;
    }

    function disableTrading() public virtual;

    function enableTrading() public virtual;

    function disableWithdrawals() public virtual;

    function enableWithdrawals() public virtual;

    function _disableTrading() internal {
        CoreStopGuardianTradingStorage storage $ = _getCoreStopGuardianTradingStorage();

        $.TRADING_GUARDIAN_TRADING_DISABLED = true;
        emit TradingDisabledUpdate(_msgSender(), true);
    }

    function _enableTrading() internal {
        CoreStopGuardianTradingStorage storage $ = _getCoreStopGuardianTradingStorage();

        delete $.TRADING_GUARDIAN_TRADING_DISABLED;
        emit TradingDisabledUpdate(_msgSender(), false);
    }

    function _disableWithdrawals() internal {
        CoreStopGuardianTradingStorage storage $ = _getCoreStopGuardianTradingStorage();

        $.TRADING_GUARDIAN_WITHDRAWALS_DISABLED = true;
        emit WithdrawalsDisabledUpdate(_msgSender(), true);
    }

    function _enableWithdrawals() internal {
        CoreStopGuardianTradingStorage storage $ = _getCoreStopGuardianTradingStorage();

        delete $.TRADING_GUARDIAN_WITHDRAWALS_DISABLED;
        emit WithdrawalsDisabledUpdate(_msgSender(), false);
    }
}
