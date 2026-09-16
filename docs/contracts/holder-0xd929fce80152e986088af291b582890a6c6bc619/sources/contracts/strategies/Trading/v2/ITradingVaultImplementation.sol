// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { CoreAccessControlConfig } from "../../../base/BaseAccessControlInitiable.sol";
import { BaseNativeWrapperConfig } from "../../../modules/native-asset-wrappers/WETH9NativeWrapperInitiable.sol";

interface ITradingVaultImplementation {
    function initialize(
        BaseNativeWrapperConfig calldata baseNativeWrapperConfig,
        CoreAccessControlConfig calldata coreAccessControlConfig,
        address _globalTradeGuardianOverride
    ) external;
}
