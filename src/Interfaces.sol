// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MarketAllocation {
    MarketParams marketParams;
    uint256 assets;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IOracle {
    function price() external view returns (uint256);
}

interface IOracleFactory {
    function createMorphoChainlinkOracleV2(
        address baseVault,
        uint256 baseVaultConversionSample,
        address baseFeed1,
        address baseFeed2,
        uint256 baseTokenDecimals,
        address quoteVault,
        uint256 quoteVaultConversionSample,
        address quoteFeed1,
        address quoteFeed2,
        uint256 quoteTokenDecimals,
        bytes32 salt
    ) external returns (address);
}

interface IMorpho {
    function createMarket(MarketParams memory marketParams) external;
    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;
    function borrow(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);
    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256);
    function position(bytes32 id, address user) external view returns (uint256, uint128, uint128);
}

interface IMetaMorphoFactory {
    function createMetaMorpho(
        address initialOwner,
        uint256 initialTimelock,
        address asset,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) external returns (address);
}

interface IMetaMorpho {
    function setCurator(address newCurator) external;
    function submitGuardian(address newGuardian) external;
    function submitCap(MarketParams memory marketParams, uint256 newSupplyCap) external;
    function acceptCap(MarketParams memory marketParams) external;
    function setSupplyQueue(bytes32[] memory newSupplyQueue) external;
    function submitTimelock(uint256 newTimelock) external;
    function transferOwnership(address newOwner) external;
    function reallocate(MarketAllocation[] memory allocations) external;
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function pendingOwner() external view returns (address);
    function curator() external view returns (address);
    function guardian() external view returns (address);
    function timelock() external view returns (uint256);
}

interface IVaultFactory {
    function deploy_new_vault(
        address asset,
        string memory name,
        string memory symbol,
        address roleManager,
        uint256 profitMaxUnlockTime
    ) external returns (address);
}

interface IYearnVault {
    function set_role(address account, uint256 role) external;
    function add_strategy(address strategy) external;
    function update_max_debt_for_strategy(address strategy, uint256 maxDebt) external;
    function set_deposit_limit(uint256 depositLimit) external;
    function set_auto_allocate(bool autoAllocate) external;
    function process_report(address strategy) external returns (uint256, uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
}
