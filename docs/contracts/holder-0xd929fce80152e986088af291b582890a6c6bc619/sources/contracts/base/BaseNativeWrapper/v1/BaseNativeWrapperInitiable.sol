// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { BaseAccessControlInitiable } from "../../BaseAccessControlInitiable.sol";
import { IBaseNativeWrapperV1 } from "./IBaseNativeWrapperV1.sol";
import { DefinitiveAssets, IERC20 } from "../../../core/libraries/DefinitiveAssets.sol";

struct BaseNativeWrapperConfig {
    address payable wrappedNativeAssetAddress;
}

abstract contract BaseNativeWrapperInitiable is IBaseNativeWrapperV1, BaseAccessControlInitiable {
    using DefinitiveAssets for IERC20;

    /// @custom:storage-location erc7201:definitive.storage.BaseNativeWrapper
    struct BaseNativeWrapperStorage {
        address payable wrappedNativeAssetAddress;
    }

    // keccak256(abi.encode(uint256(keccak256("definitive.storage.BaseNativeWrapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BaseNativeWrapperStorageLocation =
        0x57fbe06c102296dbdfaa9e064bb0d9f51d09253320913950d5de84e9a7e6e100;

    function _getBaseNativeWrapperStorage()
        private
        pure
        returns (BaseNativeWrapperStorage storage baseNativeWrapperStorage)
    {
        assembly {
            baseNativeWrapperStorage.slot := BaseNativeWrapperStorageLocation
        }
    }

    function __BaseNativeWrapperInitiable__init(
        BaseNativeWrapperConfig calldata baseNativeWrapperConfig
    ) internal onlyInitializing {
        BaseNativeWrapperStorage storage s = _getBaseNativeWrapperStorage();
        s.wrappedNativeAssetAddress = baseNativeWrapperConfig.wrappedNativeAssetAddress;
    }

    function WRAPPED_NATIVE_ASSET_ADDRESS() public view returns (address payable) {
        return _getBaseNativeWrapperStorage().wrappedNativeAssetAddress;
    }

    /**
     * @notice Publicly accessible method to wrap native assets
     * @param amount Amount of native assets to wrap
     */
    function wrap(uint256 amount) public onlyWhitelisted nonReentrant {
        _wrap(amount);
        emit NativeAssetWrap(_msgSender(), amount, true /* wrappingToNative */);
    }

    /**
     * @notice Publicly accessible method to unwrap native assets
     * @param amount Amount of tokenized assets to unwrap
     */
    function unwrap(uint256 amount) public onlyWhitelisted nonReentrant {
        _unwrap(amount);
        emit NativeAssetWrap(_msgSender(), amount, false /* wrappingToNative */);
    }

    /**
     * @notice Publicly accessible method to unwrap full balance of native assets
     * @dev Method is not marked as `nonReentrant` since it is a wrapper around `unwrap`
     */
    function unwrapAll() external onlyWhitelisted {
        return unwrap(DefinitiveAssets.getBalance(WRAPPED_NATIVE_ASSET_ADDRESS()));
    }

    /**
     * @notice Internal method to wrap native assets
     * @dev Override this method with native asset wrapping implementation
     */
    function _wrap(uint256 amount) internal virtual;

    /**
     * @notice Internal method to unwrap native assets
     * @dev Override this method with native asset unwrapping implementation
     */
    function _unwrap(uint256 amount) internal virtual;
}
