// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { BaseTransfersNativeInitiable } from "../../../base/BaseTransfersNative/v1/BaseTransfersNativeInitiable.sol";
import { BaseSimpleSwapInitiable } from "../../../base/BaseSimpleSwapInitiable.sol";
import { CoreAccessControlConfig } from "../../../base/BaseAccessControlInitiable.sol";
import { BaseRecoverSignerInitiable } from "../../../base/BaseRecoverSignerInitiable.sol";
import { CoreMulticall } from "../../../core/CoreMulticall/v1/CoreMulticall.sol";
import {
    WETH9NativeWrapperInitiable,
    BaseNativeWrapperConfig
} from "../../../modules/native-asset-wrappers/WETH9NativeWrapperInitiable.sol";
import { ITradingVaultImplementation } from "./ITradingVaultImplementation.sol";

contract TradingVaultImplementation is
    ITradingVaultImplementation,
    WETH9NativeWrapperInitiable,
    BaseTransfersNativeInitiable,
    BaseSimpleSwapInitiable,
    CoreMulticall,
    BaseRecoverSignerInitiable
{
    /// @notice Constructor on the implementation contract should call _disableInitializers()
    /// @dev https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        BaseNativeWrapperConfig calldata baseNativeWrapperConfig,
        CoreAccessControlConfig calldata coreAccessControlConfig,
        address _globalTradeGuardianOverride
    ) external override initializer {
        __WETH9NativeWrapperInitiable__init(baseNativeWrapperConfig);
        __BaseAccessControlInitiable__init(coreAccessControlConfig);

        if (_globalTradeGuardianOverride != address(0)) {
            _updateGlobalTradeGuardian(_globalTradeGuardianOverride);
        }
    }
}
