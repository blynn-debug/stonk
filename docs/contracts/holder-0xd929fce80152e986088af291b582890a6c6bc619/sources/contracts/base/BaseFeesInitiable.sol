// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { BaseAccessControlInitiable } from "./BaseAccessControlInitiable.sol";
import { DefinitiveAssets, IERC20 } from "../core/libraries/DefinitiveAssets.sol";
import { DefinitiveConstants } from "../core/libraries/DefinitiveConstants.sol";
import { InvalidFeePercent } from "../core/libraries/DefinitiveErrors.sol";
import { IGlobalGuardian } from "../tools/GlobalGuardian/IGlobalGuardian.sol";

struct CoreFeesConfig {
    address payable feeAccount;
}

abstract contract BaseFeesInitiable is BaseAccessControlInitiable {
    using DefinitiveAssets for IERC20;

    function _handleFeesOnAmount(address token, uint256 amount, uint256 feePct) internal returns (uint256 feeAmount) {
        uint256 mMaxFeePCT = DefinitiveConstants.MAX_FEE_PCT;
        if (feePct > mMaxFeePCT) {
            revert InvalidFeePercent();
        }

        feeAmount = (amount * feePct) / mMaxFeePCT;
        if (feeAmount == 0) {
            return feeAmount;
        }

        if (token == DefinitiveConstants.NATIVE_ASSET_ADDRESS) {
            if (_msgSender() == entryPoint()) {
                DefinitiveAssets.safeTransferETH(FEE_ACCOUNT(), feeAmount);
            } else {
                DefinitiveAssets.safeTransferETH(_msgSender(), feeAmount);
            }
        } else {
            IERC20(token).safeTransfer(FEE_ACCOUNT(), feeAmount);
        }
    }

    function FEE_ACCOUNT() public view returns (address) {
        return payable(IGlobalGuardian(GLOBAL_TRADE_GUARDIAN()).feeAccount());
    }
}
