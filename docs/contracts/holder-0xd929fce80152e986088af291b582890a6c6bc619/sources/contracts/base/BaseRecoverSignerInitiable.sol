// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { BaseAccessControlInitiable } from "./BaseAccessControlInitiable.sol";
import { AccountNotAdmin, InvalidSignature } from "../core/libraries/DefinitiveErrors.sol";
import { IGlobalGuardian } from "../tools/GlobalGuardian/IGlobalGuardian.sol";

/**
 * @title BaseRecoverSignerInitiable
 * @author WardenJakx
 * @notice `isValidSignature` ensures the signer is a valid client
 */
abstract contract BaseRecoverSignerInitiable is BaseAccessControlInitiable, IERC1271 {
    // bytes4(keccak256("isValidSignature(bytes32,bytes)")
    bytes4 internal constant EIP_1271_RETURN_VALUE = 0x1626ba7e;

    /**
     * @notice Verifies that the signer is the owner of the signing contract.
     */
    function isValidSignature(bytes32 _hash, bytes calldata _encodedSignature) external view override returns (bytes4) {
        (address signingAddress, bytes memory signature) = abi.decode(_encodedSignature, (address, bytes));

        if (
            !hasRole(DEFAULT_ADMIN_ROLE, signingAddress) &&
            !IGlobalGuardian(GLOBAL_TRADE_GUARDIAN()).accountIsPerformer(signingAddress)
        ) {
            revert AccountNotAdmin(signingAddress);
        }

        if (signingAddress.code.length > 0) {
            return IERC1271(signingAddress).isValidSignature(_hash, signature);
        } else if (ECDSA.recover(_hash, signature) == signingAddress) {
            return EIP_1271_RETURN_VALUE;
        }

        revert InvalidSignature();
    }
}
