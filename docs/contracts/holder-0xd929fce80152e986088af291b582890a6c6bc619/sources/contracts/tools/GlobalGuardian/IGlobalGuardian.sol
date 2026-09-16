// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { SwapPayload } from "../../core/CoreSimpleSwap/v1/ICoreSimpleSwapV1.sol";

struct SignedSwapPayload {
    address handler;
    uint256 amount;
    address swapToken;
    uint256 amountOutMin;
    bool isDelegate;
    bytes handlerCalldata;
}

interface IGlobalGuardian {
    function disable(bytes32 keyHash) external;

    function enable(bytes32 keyHash) external;

    function functionalityIsDisabled(bytes32 keyHash) external view returns (bool);

    function accountIsPerformer(address _account) external view returns (bool);

    function accountIsSwapHandler(address _account) external view returns (bool);

    function isDefinitiveAdmin() external view returns (bool);

    function isHandlerManager() external view returns (bool);

    function feeAccount() external view returns (address payable);

    function accountIsDefinitiveAdmin(address _account) external view returns (bool);

    function accountIsHandlerManager(address _account) external view returns (bool);

    function validateSwapPayloadSigner(SwapPayload calldata payload) external view;
}
