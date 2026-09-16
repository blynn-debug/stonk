// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

/**
 * @notice Contains constants used throughout the Definitive contracts
 * @dev This file should only be used as an internal library.
 */
library DefinitiveConstants {
    /**
     * @notice Maximum fee percentage
     */
    uint256 internal constant MAX_FEE_PCT = 10000;

    /**
     * @notice Address to signify native assets
     */
    address internal constant NATIVE_ASSET_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /**
     * @notice Maximum number of swaps allowed per block
     */
    uint8 internal constant MAX_SWAPS_PER_BLOCK = 25;

    struct Assets {
        uint256[] amounts;
        address[] addresses;
    }

    address internal constant DEFAULT_GLOBAL_TRADE_GUARDIAN = 0xE3F35754954B0B77958C72b83EC5205971463064;

    address internal constant STAGING_GLOBAL_TRADE_GUARDIAN = 0xE217abF1077eC4772E4E78Ca0802046A974cba90;

    address internal constant LOCAL_GLOBAL_TRADE_GUARDIAN = 0x92d4Ba061336C223f774A23f9a385B7eAdFA64A6;

    address internal constant GENERIC_UUPS_PROXY_IMPLEMENTATION = 0x4aEb164998DB4eB8ab945620d4d1db59E2Ad5513;

    address internal constant SEND_FEE_TO_SENDER_ALIAS = address(0xFEE);

    address internal constant BLAST_NATIVE_YIELD_CONTRACT = 0x4300000000000000000000000000000000000002;

    address internal constant BLAST_POINTS_ADDRESS = 0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800;

    address internal constant BLAST_DEFINITIVE_OPERATOR_PROD = 0xaba36De8208002e05a757377A76D50093233Eb51;

    address internal constant BLAST_DEFINITIVE_OPERATOR_STAGING = 0xaf212671793921BCb84F04cEeEd1dec1EF742DAC;

    address internal constant ENTRYPOINT_0_7 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
}
