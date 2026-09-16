// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import { AccessControl as OZAccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ICoreAccessControlV1, CoreAccessControlConfig } from "./ICoreAccessControlV1.sol";
import { AccountNotAdmin, AccountNotWhitelisted, AccountMissingRole } from "../../libraries/DefinitiveErrors.sol";
import { IGlobalGuardian } from "../../../tools/GlobalGuardian/IGlobalGuardian.sol";
import { CoreGlobalGuardian } from "../../CoreGlobalGuardian/CoreGlobalGuardian.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { CoreAccountAbstraction, Unauthorized } from "../../CoreAccountAbstraction/CoreAccountAbstraction.sol";

abstract contract CoreAccessControlInitiable is
    ICoreAccessControlV1,
    OZAccessControl,
    Initializable,
    CoreGlobalGuardian,
    ReentrancyGuardUpgradeable,
    CoreAccountAbstraction
{
    /// @custom:storage-location erc7201:definitive.storage.CoreAccessControl
    struct CoreAccessControlStorage {
        mapping(bytes32 => RoleDataPasskeys) roles;
    }

    struct RoleDataPasskeys {
        mapping(bytes => bool) hasRole;
        bytes32 adminRole;
    }

    /* solhint-disable max-line-length */
    // keccak256(abi.encode(uint256(keccak256("definitive.storage.CoreAccessControl")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CoreAccessControlStorageLocation =
        0x2d4c43e2acbd2a853aab6947a7bb2f7cae5309ca1d492e32a85b53ceb22cc800;

    /* solhint-enable max-line-length */
    function _getCoreAccessControlStorage() private pure returns (CoreAccessControlStorage storage $) {
        /// @solidity memory-safe-assembly
        assembly {
            $.slot := CoreAccessControlStorageLocation
        }
    }

    // roles
    bytes32 public constant ROLE_DEFINITIVE = keccak256("DEFINITIVE");
    bytes32 public constant ROLE_DEFINITIVE_ADMIN = keccak256("DEFINITIVE_ADMIN");
    bytes32 public constant ROLE_CLIENT = keccak256("CLIENT");
    bytes32 public constant ROLE_TRADER = keccak256("TRADER");

    modifier onlyDefinitive() {
        if (!_accountIsPerformer(_msgSender()) && msg.sender != entryPoint()) {
            revert AccountMissingRole(_msgSender(), ROLE_DEFINITIVE);
        }
        _;
    }
    modifier onlyDefinitiveAdmin() {
        bool isDefinitiveAdmin = IGlobalGuardian(GLOBAL_TRADE_GUARDIAN()).accountIsDefinitiveAdmin(_msgSender());
        if (!isDefinitiveAdmin) {
            revert AccountMissingRole(_msgSender(), ROLE_DEFINITIVE_ADMIN);
        }
        _;
    }
    modifier onlyClientAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && msg.sender != entryPoint()) {
            revert AccountMissingRole(_msgSender(), DEFAULT_ADMIN_ROLE);
        }
        _;
    }

    // default admin + definitive admin
    modifier onlyAdmins() {
        bool isAdmins = (hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) ||
            IGlobalGuardian(GLOBAL_TRADE_GUARDIAN()).accountIsDefinitiveAdmin(_msgSender()));
        if (!isAdmins) {
            revert AccountNotAdmin(_msgSender());
        }
        _;
    }
    // client + definitive
    modifier onlyWhitelisted() {
        bool isWhitelisted = (hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) ||
            IGlobalGuardian(GLOBAL_TRADE_GUARDIAN()).accountIsPerformer(_msgSender()));
        if (!isWhitelisted) {
            revert AccountNotWhitelisted(_msgSender());
        }
        _;
    }

    modifier onlyEntryPointOrClient() {
        if (msg.sender != entryPoint() && !hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            revert Unauthorized();
        }
        _;
    }

    function isPasskeyClient(bytes memory account) public view returns (bool) {
        return _getCoreAccessControlStorage().roles[DEFAULT_ADMIN_ROLE].hasRole[account];
    }

    function isPasskeyTrader(bytes memory account) public view returns (bool) {
        return _getCoreAccessControlStorage().roles[ROLE_TRADER].hasRole[account];
    }

    function __CoreAccessControlInitiable__init(CoreAccessControlConfig calldata cfg) internal onlyInitializing {
        __ReentrancyGuard_init();

        // admin
        _grantRole(DEFAULT_ADMIN_ROLE, cfg.admin);

        uint256 cfgClientLength = cfg.client.length;
        for (uint256 i; i < cfgClientLength; ) {
            _grantRole(ROLE_CLIENT, cfg.client[i]);
            _grantRole(DEFAULT_ADMIN_ROLE, cfg.client[i]);
            unchecked {
                ++i;
            }
        }

        CoreAccessControlStorage storage $ = _getCoreAccessControlStorage();
        for (uint256 i; i < cfg.passkeyClients.length; ) {
            $.roles[DEFAULT_ADMIN_ROLE].hasRole[cfg.passkeyClients[i]] = true;

            unchecked {
                ++i;
            }
        }

        /// Traders are NOT clients as should not be able to withdraw
        /// We must create a role specific to traders (is still backwards compatible)
        for (uint256 i; i < cfg.traders.length; ) {
            $.roles[ROLE_TRADER].hasRole[cfg.passkeyTraders[i]] = true;

            unchecked {
                ++i;
            }
        }
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) public payable override onlyEntryPointOrClient returns (bytes memory result) {
        return _execute(target, value, data);
    }

    function executeBatch(
        Call[] calldata calls
    ) public payable override onlyEntryPointOrClient returns (bytes[] memory results) {
        return _executeBatch(calls);
    }

    function _checkRole(bytes32 role, address account) internal view virtual override {
        if (!hasRole(role, account)) {
            revert AccountMissingRole(account, role);
        }
    }

    function _checkAccountIsPerformer(address account) internal view virtual {
        if (!_accountIsPerformer(account)) {
            revert AccountMissingRole(account, ROLE_DEFINITIVE);
        }
    }

    function _accountIsPerformer(address account) internal view returns (bool) {
        return IGlobalGuardian(GLOBAL_TRADE_GUARDIAN()).accountIsPerformer(account);
    }

    /**
     * @dev Grants passkey client role to the given account.
     *
     * Requirements:
     * - the caller must have the DEFAULT_ADMIN_ROLE.
     */
    function grantPasskeyClientRole(bytes memory account) public virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        CoreAccessControlStorage storage $ = _getCoreAccessControlStorage();
        if (!$.roles[DEFAULT_ADMIN_ROLE].hasRole[account]) {
            $.roles[DEFAULT_ADMIN_ROLE].hasRole[account] = true;
            emit RoleGranted(DEFAULT_ADMIN_ROLE, address(bytes20(account)), _msgSender());
        }
    }

    /**
     * @dev Revokes passkey client role from the given account.
     *
     * Requirements:
     * - the caller must have the DEFAULT_ADMIN_ROLE.
     */
    function revokePasskeyClientRole(bytes memory account) public virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        CoreAccessControlStorage storage $ = _getCoreAccessControlStorage();
        if ($.roles[DEFAULT_ADMIN_ROLE].hasRole[account]) {
            $.roles[DEFAULT_ADMIN_ROLE].hasRole[account] = false;
            emit RoleRevoked(DEFAULT_ADMIN_ROLE, address(bytes20(account)), _msgSender());
        }
    }

    /**
     * @dev Grants passkey trader role to the given account.
     *
     * Requirements:
     * - the caller must have either the DEFAULT_ADMIN_ROLE or ROLE_TRADER.
     */
    function grantPasskeyTraderRole(bytes memory account) public virtual {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !hasRole(ROLE_TRADER, _msgSender())) {
            revert AccountMissingRole(_msgSender(), DEFAULT_ADMIN_ROLE);
        }
        CoreAccessControlStorage storage $ = _getCoreAccessControlStorage();
        if (!$.roles[ROLE_TRADER].hasRole[account]) {
            $.roles[ROLE_TRADER].hasRole[account] = true;
            emit RoleGranted(ROLE_TRADER, address(bytes20(account)), _msgSender());
        }
    }

    /**
     * @dev Revokes passkey trader role from the given account.
     *
     * Requirements:
     * - the caller must have the DEFAULT_ADMIN_ROLE.
     */
    function revokePasskeyTraderRole(bytes memory account) public virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        CoreAccessControlStorage storage $ = _getCoreAccessControlStorage();
        if ($.roles[ROLE_TRADER].hasRole[account]) {
            $.roles[ROLE_TRADER].hasRole[account] = false;
            emit RoleRevoked(ROLE_TRADER, address(bytes20(account)), _msgSender());
        }
    }
}
