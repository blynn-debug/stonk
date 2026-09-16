// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

abstract contract CoreGlobalGuardian {
    event GlobalTradeGuardianUpdate(address indexed globalTradeGuardian);

    /// @custom:storage-location erc7201:definitive.storage.CoreGlobalGuardian
    struct CoreGlobalGuardianStorage {
        address GLOBAL_TRADE_GUARDIAN;
    }

    /// keccak256(abi.encode(uint256(keccak256("definitive.storage.CoreGlobalGuardian"))- 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CoreGlobalGuardianStorageLocation =
        0x96888095fca464b4a45fa21ec2cd73681252b1aee41fb5e30dbff9a53008bb00;

    function _getCoreGlobalGuardianStorage() private pure returns (CoreGlobalGuardianStorage storage $) {
        assembly {
            $.slot := CoreGlobalGuardianStorageLocation
        }
    }

    function GLOBAL_TRADE_GUARDIAN() public view returns (address) {
        CoreGlobalGuardianStorage storage $ = _getCoreGlobalGuardianStorage();
        return $.GLOBAL_TRADE_GUARDIAN;
    }

    function updateGlobalTradeGuardian(address _globalTradeGuardian) external virtual;

    function _updateGlobalTradeGuardian(address _globalTradeGuardian) internal {
        CoreGlobalGuardianStorage storage $ = _getCoreGlobalGuardianStorage();
        $.GLOBAL_TRADE_GUARDIAN = _globalTradeGuardian;
        emit GlobalTradeGuardianUpdate(_globalTradeGuardian);
    }
}
