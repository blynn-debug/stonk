// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

struct CoreAccessControlConfig {
    address admin;
    address[] client;
    address[] traders;
    // admin = clients
    bytes[] passkeyClients;
    bytes[] passkeyTraders;
}

interface ICoreAccessControlV1 is IAccessControl {
    function ROLE_CLIENT() external returns (bytes32);

    function ROLE_DEFINITIVE() external returns (bytes32);

    function ROLE_DEFINITIVE_ADMIN() external returns (bytes32);
}
