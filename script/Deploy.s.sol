// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {BaseAddresses as A} from "src/Addresses.sol";
import {
    IERC20,
    IMetaMorpho,
    IMetaMorphoFactory,
    IMorpho,
    IOracleFactory,
    IVaultFactory,
    IYearnVault,
    MarketParams
} from "src/Interfaces.sol";

contract Deploy is Script {
    struct MarketCfg {
        address collateral;
        uint256 decimals;
        address feed;
        uint256 lltv;
    }

    struct Deployment {
        address morphoVault;
        address yvBRS;
        MarketParams[] markets;
    }

    uint256 internal constant SEED = 1e6;
    uint256 internal constant MARKET_CAP = 250_000e6;
    uint256 internal constant DEPOSIT_LIMIT = 500_000e6;
    uint256 internal constant MORPHO_TIMELOCK = 3 days;
    uint256 internal constant PROFIT_UNLOCK = 7 days;
    uint256 internal constant YV_ROLES = 1 | 32 | 64 | 128 | 256;

    function markets() public pure returns (MarketCfg[] memory m) {
        m = new MarketCfg[](4);
        m[0] = MarketCfg(A.TESOURO, 6, A.TESOURO_USD, 0.86e18);
        m[1] = MarketCfg(A.USDC, 6, A.USDC_USD, 0.86e18);
        m[2] = MarketCfg(A.CBBTC, 8, A.CBBTC_USD, 0.77e18);
        m[3] = MarketCfg(A.WETH, 18, A.ETH_USD, 0.77e18);
    }

    function run() external returns (Deployment memory d) {
        address owner = vm.envAddress("OWNER");
        address curator = vm.envAddress("CURATOR");
        address guardian = vm.envAddress("GUARDIAN");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        MarketCfg[] memory cfgs = markets();
        d.markets = new MarketParams[](cfgs.length);
        bytes32[] memory supplyQueue = new bytes32[](cfgs.length);

        IERC20(A.BRS).approve(A.MORPHO, SEED * cfgs.length);
        for (uint256 i; i < cfgs.length; i++) {
            address oracle = IOracleFactory(A.ORACLE_FACTORY).createMorphoChainlinkOracleV2(
                address(0), 1, cfgs[i].feed, address(0), cfgs[i].decimals, address(0), 1, A.BRL_USD, address(0), 6, 0
            );
            MarketParams memory p = MarketParams(A.BRS, cfgs[i].collateral, oracle, A.ADAPTIVE_CURVE_IRM, cfgs[i].lltv);
            IMorpho(A.MORPHO).createMarket(p);
            IMorpho(A.MORPHO).supply(p, SEED, 0, A.DEAD, "");
            d.markets[i] = p;
            supplyQueue[i] = keccak256(abi.encode(p));
        }

        IMetaMorpho mv = IMetaMorpho(
            IMetaMorphoFactory(A.METAMORPHO_FACTORY).createMetaMorpho(
                deployer, 0, A.BRS, "Yearn Degen BRS", "ymvDegen-BRS", 0
            )
        );
        for (uint256 i; i < cfgs.length; i++) {
            mv.submitCap(d.markets[i], MARKET_CAP);
            mv.acceptCap(d.markets[i]);
        }
        mv.setSupplyQueue(supplyQueue);
        IERC20(A.BRS).approve(address(mv), SEED);
        mv.deposit(SEED, A.DEAD);
        mv.setCurator(curator);
        mv.submitGuardian(guardian);
        mv.submitTimelock(MORPHO_TIMELOCK);
        mv.transferOwnership(owner);

        IYearnVault yv = IYearnVault(
            IVaultFactory(A.YEARN_VAULT_FACTORY).deploy_new_vault(A.BRS, "BRS yVault", "yvBRS", deployer, PROFIT_UNLOCK)
        );
        yv.set_role(deployer, YV_ROLES);
        yv.add_strategy(address(mv));
        yv.update_max_debt_for_strategy(address(mv), type(uint256).max);
        yv.set_deposit_limit(DEPOSIT_LIMIT);
        yv.set_auto_allocate(true);

        vm.stopBroadcast();

        d.morphoVault = address(mv);
        d.yvBRS = address(yv);

        console2.log("deployer", deployer);
        console2.log("morpho vault", d.morphoVault);
        console2.log("yvBRS", d.yvBRS);
        for (uint256 i; i < cfgs.length; i++) {
            console2.log("market collateral / oracle", d.markets[i].collateralToken, d.markets[i].oracle);
            console2.logBytes32(supplyQueue[i]);
        }
    }
}
