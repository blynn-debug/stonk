// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { ICoreDepositV1 } from "./ICoreDepositV1.sol";
import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { DefinitiveAssets, IERC20 } from "../../libraries/DefinitiveAssets.sol";

import { InvalidInputs } from "../../libraries/DefinitiveErrors.sol";

abstract contract CoreDeposit is ICoreDepositV1, Context {
    using DefinitiveAssets for IERC20;

    function deposit(uint256[] calldata amounts, address[] calldata assetAddresses) external payable virtual;

    function _deposit(uint256[] calldata amounts, address[] calldata erc20Tokens) internal virtual {
        _depositERC20(amounts, erc20Tokens);

        emit Deposit(_msgSender(), erc20Tokens, amounts);
    }

    function _depositERC20(uint256[] calldata amounts, address[] calldata erc20Tokens) internal {
        uint256 amountsLength = amounts.length;
        if (amountsLength != erc20Tokens.length) {
            revert InvalidInputs();
        }

        for (uint256 i; i < amountsLength; ) {
            IERC20(erc20Tokens[i]).safeTransferFrom(_msgSender(), address(this), amounts[i]);
            unchecked {
                ++i;
            }
        }
    }
}
