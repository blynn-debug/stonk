// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import {
    CoreAccessControlInitiable,
    CoreAccessControlConfig
} from "../core/CoreAccessControl/v1/CoreAccessControlInitiable.sol";
import { CoreStopGuardian } from "../core/CoreStopGuardian/v1/CoreStopGuardian.sol";

import { CoreStopGuardianTrading } from "../core/CoreStopGuardianTrading/v1/CoreStopGuardianTrading.sol";
import { DefinitiveConstants } from "../core/libraries/DefinitiveConstants.sol";
import { ICoreSimpleSwapV1 } from "../core/CoreSimpleSwap/v1/ICoreSimpleSwapV1.sol";
import { InvalidMethod } from "../core/libraries/DefinitiveErrors.sol";
import { SignatureCheckerLib } from "../tools/SoladySnippets/SignatureCheckerLib.sol";

abstract contract BaseAccessControlInitiable is CoreAccessControlInitiable, CoreStopGuardian, CoreStopGuardianTrading {
    /**
     * @dev
     * Modifiers inherited from CoreAccessControl:
     * onlyDefinitive
     * onlyWhitelisted
     * onlyClientAdmin
     * onlyDefinitiveAdmin
     *
     * Modifiers inherited from CoreStopGuardian:
     * stopGuarded
     */

    function __BaseAccessControlInitiable__init(
        CoreAccessControlConfig calldata coreAccessControlConfig
    ) internal onlyInitializing {
        __CoreAccessControlInitiable__init(coreAccessControlConfig);
        _updateGlobalTradeGuardian(DefinitiveConstants.DEFAULT_GLOBAL_TRADE_GUARDIAN);
    }

    /// @dev Validate `userOp.signature` for the `userOpHash`.
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal view override returns (uint256 validationData) {
        (address signerAddress, bytes memory signature) = abi.decode(userOp.signature, (address, bytes));
        bytes4 methodSig = bytes4(userOp.callData);

        if (hasRole(DEFAULT_ADMIN_ROLE, signerAddress)) {
            // Allow clients and admin to sign any method
        } else if (_isAuthorizedDefinitiveMethod(methodSig)) {
            _checkAccountIsPerformer(signerAddress);
        } else {
            revert InvalidMethod(methodSig);
        }

        bool success = SignatureCheckerLib.isValidSignatureNow(
            signerAddress,
            SignatureCheckerLib.toEthSignedMessageHash(userOpHash),
            signature
        );

        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Returns 0 if the recovered address matches the owner.
            // Else returns 1, which is equivalent to:
            // `(success ? 0 : 1) | (uint256(validUntil) << 160) | (uint256(validAfter) << (160 + 48))`
            // where `validUntil` is 0 (indefinite) and `validAfter` is 0.
            validationData := iszero(success)
        }
    }

    function _isAuthorizedDefinitiveMethod(bytes4 methodSig) internal pure returns (bool) {
        return methodSig == ICoreSimpleSwapV1.swap.selector;
    }

    /**
     * @dev Inherited from CoreStopGuardianTrading
     */
    function updateGlobalTradeGuardian(address _globalTradeGuardian) external override onlyAdmins {
        return _updateGlobalTradeGuardian(_globalTradeGuardian);
    }

    /**
     * @dev Inherited from CoreStopGuardian
     */
    function enableStopGuardian() public override onlyAdmins {
        return _enableStopGuardian();
    }

    /**
     * @dev Inherited from CoreStopGuardian
     */
    function disableStopGuardian() public override onlyClientAdmin {
        return _disableStopGuardian();
    }

    /**
     * @dev Inherited from CoreStopGuardianTrading
     */

    function disableTrading() public override onlyAdmins {
        return _disableTrading();
    }

    /**
     * @dev Inherited from CoreStopGuardianTrading
     */
    function enableTrading() public override onlyAdmins {
        return _enableTrading();
    }

    /**
     * @dev Inherited from CoreStopGuardianTrading
     */
    function disableWithdrawals() public override onlyClientAdmin {
        return _disableWithdrawals();
    }

    /**
     * @dev Inherited from CoreStopGuardianTrading
     */
    function enableWithdrawals() public override onlyClientAdmin {
        return _enableWithdrawals();
    }
}
