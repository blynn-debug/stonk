// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import {
    BaseNativeWrapperInitiable,
    BaseNativeWrapperConfig
} from "../../base/BaseNativeWrapper/v1/BaseNativeWrapperInitiable.sol";
import { IWETH9 } from "../../vendor/interfaces/IWETH9.sol";

abstract contract WETH9NativeWrapperInitiable is BaseNativeWrapperInitiable {
    function __WETH9NativeWrapperInitiable__init(BaseNativeWrapperConfig calldata config) internal onlyInitializing {
        __BaseNativeWrapperInitiable__init(config);
    }

    function _wrap(uint256 amount) internal override {
        // slither-disable-next-line arbitrary-send-eth
        IWETH9(WRAPPED_NATIVE_ASSET_ADDRESS()).deposit{ value: amount }();
    }

    function _unwrap(uint256 amount) internal override {
        IWETH9(WRAPPED_NATIVE_ASSET_ADDRESS()).withdraw(amount);
    }
}
