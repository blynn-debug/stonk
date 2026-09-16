// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { CoreDeposit } from "../../../core/CoreDeposit/v1/CoreDeposit.sol";
import { CoreWithdraw } from "../../../core/CoreWithdraw/v1/CoreWithdraw.sol";
import { BaseAccessControlInitiable } from "../../BaseAccessControlInitiable.sol";

abstract contract BaseTransfersInitiable is CoreDeposit, CoreWithdraw, BaseAccessControlInitiable {
    function deposit(
        uint256[] calldata amounts,
        address[] calldata erc20Tokens
    ) external payable virtual override onlyClientAdmin nonReentrant stopGuarded {
        return _deposit(amounts, erc20Tokens);
    }

    function withdraw(
        uint256 amount,
        address erc20Token
    ) public virtual override onlyClientAdmin nonReentrant stopGuarded withdrawalsEnabled returns (bool) {
        return _withdraw(amount, erc20Token);
    }

    function withdrawTo(
        uint256 amount,
        address erc20Token,
        address to
    ) public virtual override onlyWhitelisted nonReentrant stopGuarded withdrawalsEnabled returns (bool) {
        // `to` account must be a client
        _checkRole(ROLE_CLIENT, to);

        return _withdrawTo(amount, erc20Token, to);
    }

    function withdrawAll(
        address[] calldata tokens
    ) public virtual override onlyClientAdmin nonReentrant stopGuarded withdrawalsEnabled returns (bool) {
        return _withdrawAll(tokens);
    }

    function withdrawAllTo(
        address[] calldata tokens,
        address to
    ) public virtual override onlyWhitelisted stopGuarded withdrawalsEnabled returns (bool) {
        _checkRole(ROLE_CLIENT, to);
        return _withdrawAllTo(tokens, to);
    }

    function supportsNativeAssets() public pure virtual override returns (bool) {
        return false;
    }
}
