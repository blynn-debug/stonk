// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { ICoreSimpleSwapV1 } from "./ICoreSimpleSwapV1.sol";
import { DefinitiveAssets, IERC20 } from "../../libraries/DefinitiveAssets.sol";
import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { CallUtils } from "../../../tools/BubbleReverts/BubbleReverts.sol";
import { DefinitiveConstants } from "../../libraries/DefinitiveConstants.sol";
import {
    InvalidSwapHandler,
    InsufficientSwapTokenBalance,
    SwapTokenIsOutputToken,
    InvalidOutputToken,
    InvalidReportedOutputAmount,
    InvalidExecutedOutputAmount,
    InvalidSwapInputAmount
} from "../../libraries/DefinitiveErrors.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { SwapPayload } from "./ICoreSimpleSwapV1.sol";
import { CoreGlobalGuardian } from "../../CoreGlobalGuardian/CoreGlobalGuardian.sol";
import { IGlobalGuardian } from "../../../tools/GlobalGuardian/IGlobalGuardian.sol";

struct CoreSimpleSwapConfig {
    address[] swapHandlers;
}

abstract contract CoreSimpleSwapInitiable is ICoreSimpleSwapV1, Context, Initializable, CoreGlobalGuardian {
    using DefinitiveAssets for IERC20;

    function swap(
        SwapPayload[] memory payloads,
        address outputToken,
        uint256 amountOutMin,
        uint256 feePct
    ) external payable virtual returns (uint256 outputAmount);

    /* solhint-disable code-complexity */

    function _swap(
        SwapPayload[] memory payloads,
        address expectedOutputToken
    ) internal returns (uint256[] memory inputTokenAmounts, uint256 outputTokenAmount) {
        uint256 payloadsLength = payloads.length;
        inputTokenAmounts = new uint256[](payloadsLength);
        uint256 outputTokenBalanceStart = DefinitiveAssets.getBalance(expectedOutputToken);
        address mGLOBAL_TRADE_GUARDIAN = GLOBAL_TRADE_GUARDIAN();
        address mSEND_FEE_TO_SENDER_ALIAS = DefinitiveConstants.SEND_FEE_TO_SENDER_ALIAS;

        for (uint256 i; i < payloadsLength; ) {
            SwapPayload memory payload = payloads[i];

            if (
                payload.handler == mSEND_FEE_TO_SENDER_ALIAS &&
                payload.swapToken == DefinitiveConstants.NATIVE_ASSET_ADDRESS
            ) {
                inputTokenAmounts[i] = payload.amount;
                if (_msgSender() == DefinitiveConstants.ENTRYPOINT_0_7) {
                    DefinitiveAssets.safeTransferETH(
                        IGlobalGuardian(mGLOBAL_TRADE_GUARDIAN).feeAccount(),
                        payload.amount
                    );
                } else {
                    DefinitiveAssets.safeTransferETH(_msgSender(), payload.amount);
                }

                unchecked {
                    ++i;
                }
                continue;
            }

            if (payload.handler == mSEND_FEE_TO_SENDER_ALIAS) {
                inputTokenAmounts[i] = payload.amount;
                DefinitiveAssets.safeTransfer(
                    IERC20(payload.swapToken),
                    IGlobalGuardian(mGLOBAL_TRADE_GUARDIAN).feeAccount(),
                    payload.amount
                );
                unchecked {
                    ++i;
                }
                continue;
            }

            if (!IGlobalGuardian(mGLOBAL_TRADE_GUARDIAN).accountIsSwapHandler(payload.handler)) {
                revert InvalidSwapHandler();
            }

            if (expectedOutputToken == payload.swapToken) {
                revert SwapTokenIsOutputToken();
            }

            uint256 outputTokenBalanceBefore = DefinitiveAssets.getBalance(expectedOutputToken);
            inputTokenAmounts[i] = DefinitiveAssets.getBalance(payload.swapToken);

            (uint256 _outputAmount, address _outputToken) = _processSwap(payload, expectedOutputToken);

            if (_outputToken != expectedOutputToken) {
                revert InvalidOutputToken();
            }
            if (_outputAmount < payload.amountOutMin) {
                revert InvalidReportedOutputAmount();
            }
            uint256 outputTokenBalanceAfter = DefinitiveAssets.getBalance(expectedOutputToken);

            if ((outputTokenBalanceAfter - outputTokenBalanceBefore) < payload.amountOutMin) {
                revert InvalidExecutedOutputAmount();
            }

            // Update `inputTokenAmounts` to reflect the amount of tokens actually swapped
            inputTokenAmounts[i] -= DefinitiveAssets.getBalance(payload.swapToken);
            unchecked {
                ++i;
            }
        }

        outputTokenAmount = DefinitiveAssets.getBalance(expectedOutputToken) - outputTokenBalanceStart;
    }

    /* solhint-enable code-complexity */

    function _processSwap(SwapPayload memory payload, address expectedOutputToken) private returns (uint256, address) {
        // Override payload.amount with validated amount
        payload.amount = _getValidatedPayloadAmount(payload);

        bytes memory _calldata = _getEncodedSwapHandlerCalldata(payload, expectedOutputToken, payload.isDelegate);

        bool _success;
        bytes memory _returnBytes;
        if (payload.isDelegate) {
            // slither-disable-next-line all
            (_success, _returnBytes) = payload.handler.delegatecall(_calldata);
        } else {
            uint256 msgValue = _prepareAssetsForNonDelegateHandlerCall(payload, payload.amount);
            (_success, _returnBytes) = payload.handler.call{ value: msgValue }(_calldata);
        }

        if (!_success) {
            CallUtils.revertFromReturnedData(_returnBytes);
        }

        return abi.decode(_returnBytes, (uint256, address));
    }

    function _getEncodedSwapHandlerCalldata(
        SwapPayload memory payload,
        address expectedOutputToken,
        bool isDelegateCall
    ) internal pure virtual returns (bytes memory);

    function _getValidatedPayloadAmount(SwapPayload memory payload) private view returns (uint256 amount) {
        uint256 balance = DefinitiveAssets.getBalance(payload.swapToken);

        // Ensure balance > 0
        DefinitiveAssets.validateAmount(balance);

        amount = payload.amount;

        if (amount == 0) {
            revert InvalidSwapInputAmount();
        }

        if (balance < amount) {
            revert InsufficientSwapTokenBalance();
        }
    }

    function _prepareAssetsForNonDelegateHandlerCall(
        SwapPayload memory payload,
        uint256 amount
    ) private returns (uint256 msgValue) {
        if (payload.swapToken == DefinitiveConstants.NATIVE_ASSET_ADDRESS) {
            return amount;
        } else {
            IERC20(payload.swapToken).resetAndSafeIncreaseAllowance(payload.handler, amount);
        }
    }
}
