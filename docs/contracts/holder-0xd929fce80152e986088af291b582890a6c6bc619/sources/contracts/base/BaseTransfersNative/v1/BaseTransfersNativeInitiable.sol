// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { IBaseNativeWrapperV1 } from "../../BaseNativeWrapper/v1/IBaseNativeWrapperV1.sol";
import { BaseTransfersInitiable } from "../../BaseTransfers/v1/BaseTransfersInitiable.sol";
import { CoreTransfersNative } from "../../../core/CoreTransfersNative/v1/CoreTransfersNative.sol";

abstract contract BaseTransfersNativeInitiable is IBaseNativeWrapperV1, CoreTransfersNative, BaseTransfersInitiable {
    function deposit(
        uint256[] calldata amounts,
        address[] calldata assetAddresses
    ) external payable override onlyClientAdmin nonReentrant stopGuarded {
        _depositNativeAndERC20(amounts, assetAddresses);
        emit Deposit(_msgSender(), assetAddresses, amounts);
    }

    function supportsNativeAssets() public pure virtual override returns (bool) {
        return true;
    }
}
