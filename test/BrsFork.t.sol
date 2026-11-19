// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {BaseAddresses as A} from "src/Addresses.sol";
import {
    IERC20, IFeed, IMetaMorpho, IMorpho, IOracle, IYearnVault, MarketAllocation, MarketParams
} from "src/Interfaces.sol";

contract BrsForkTest is Test {
    address internal constant OWNER = 0xFEaE2F855250c36A77b8C68dB07C4dD9711fE36F;
    address internal constant CURATOR = 0x90D0f26025571295D18a6c041E47450B81886B51;
    address internal constant GUARDIAN = 0xbfAABa9F56A39B814281D68d2Ad949e88D06b02E;
    uint256 internal constant DEPOSIT = 400_000e6;
    uint256 internal constant BORROW = 50_000e6;

    IMorpho internal constant MORPHO = IMorpho(A.MORPHO);
    IERC20 internal constant BRS = IERC20(A.BRS);

    Deploy internal script;
    IMetaMorpho internal mv;
    IYearnVault internal yv;
    MarketParams[] internal markets;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        vm.setEnv("OWNER", vm.toString(OWNER));
        vm.setEnv("CURATOR", vm.toString(CURATOR));
        vm.setEnv("GUARDIAN", vm.toString(GUARDIAN));
        deal(A.BRS, DEFAULT_SENDER, 5e6);

        script = new Deploy();
        Deploy.Deployment memory d = script.run();
        mv = IMetaMorpho(d.morphoVault);
        yv = IYearnVault(d.yvBRS);
        for (uint256 i; i < d.markets.length; i++) {
            markets.push(d.markets[i]);
        }
    }

    function test_vaultRoles() public view {
        assertEq(mv.pendingOwner(), OWNER);
        assertEq(mv.curator(), CURATOR);
        assertEq(mv.guardian(), GUARDIAN);
        assertEq(mv.timelock(), 3 days);
    }

    function test_oraclePrices() public view {
        Deploy.MarketCfg[] memory cfgs = script.markets();
        (, int256 brlUsd,,,) = IFeed(A.BRL_USD).latestRoundData();
        for (uint256 i; i < cfgs.length; i++) {
            (, int256 collUsd,,,) = IFeed(cfgs[i].feed).latestRoundData();
            uint256 expected = uint256(collUsd) * 10 ** (36 + BRS.decimals() + IFeed(A.BRL_USD).decimals())
                / (uint256(brlUsd) * 10 ** (IERC20(cfgs[i].collateral).decimals() + IFeed(cfgs[i].feed).decimals()));
            assertApproxEqRel(IOracle(markets[i].oracle).price(), expected, 0.01e18);
        }
        uint256 brsPerUsdc = IOracle(markets[1].oracle).price() * 1e6 / 1e36;
        assertGt(brsPerUsdc, 4e6);
        assertLt(brsPerUsdc, 8e6);
    }

    function test_lendBorrowReportWithdraw() public {
        _seedLiquidity();
        for (uint256 i; i < markets.length; i++) {
            _borrow(i, _borrower(i));
        }

        skip(30 days);
        vm.prank(DEFAULT_SENDER);
        (uint256 gain, uint256 loss) = yv.process_report(address(mv));
        assertGt(gain, 0);
        assertEq(loss, 0);

        for (uint256 i; i < markets.length; i++) {
            address b = _borrower(i);
            (, uint128 shares,) = MORPHO.position(keccak256(abi.encode(markets[i])), b);
            deal(A.BRS, b, BORROW * 2);
            vm.startPrank(b);
            BRS.approve(A.MORPHO, type(uint256).max);
            MORPHO.repay(markets[i], 0, shares, b, "");
            vm.stopPrank();
        }

        skip(7 days);
        uint256 yvShares = yv.maxRedeem(alice);
        vm.prank(alice);
        uint256 out = yv.redeem(yvShares, alice, alice);
        assertGt(out, DEPOSIT);
    }

    function test_liquidation() public {
        _seedLiquidity();
        uint256 i = 3;
        address b = _borrower(i);
        _borrow(i, b);
        bytes32 id = keccak256(abi.encode(markets[i]));
        (, uint128 shares,) = MORPHO.position(id, b);

        address liquidator = makeAddr("liquidator");
        deal(A.BRS, liquidator, BORROW);
        vm.startPrank(liquidator);
        BRS.approve(A.MORPHO, type(uint256).max);
        vm.expectRevert();
        MORPHO.liquidate(markets[i], b, 0, shares / 2, "");

        address feed = script.markets()[i].feed;
        (uint80 r, int256 answer, uint256 s, uint256 u, uint80 ar) = IFeed(feed).latestRoundData();
        vm.mockCall(feed, abi.encodeWithSelector(IFeed.latestRoundData.selector), abi.encode(r, answer * 55 / 100, s, u, ar));
        (uint256 seized,) = MORPHO.liquidate(markets[i], b, 0, shares / 2, "");
        vm.stopPrank();

        (, uint128 sharesAfter,) = MORPHO.position(id, b);
        assertEq(sharesAfter, shares - shares / 2);
        assertGt(seized, 0);
        assertEq(IERC20(markets[i].collateralToken).balanceOf(liquidator), seized);
    }

    function _seedLiquidity() internal {
        deal(A.BRS, alice, DEPOSIT);
        vm.startPrank(alice);
        BRS.approve(address(yv), DEPOSIT);
        yv.deposit(DEPOSIT, alice);
        vm.stopPrank();

        MarketAllocation[] memory allocs = new MarketAllocation[](markets.length);
        for (uint256 i; i < markets.length; i++) {
            allocs[i] = MarketAllocation(markets[i], i == markets.length - 1 ? type(uint256).max : DEPOSIT / 4);
        }
        vm.prank(CURATOR);
        mv.reallocate(allocs);
    }

    function _borrow(uint256 i, address b) internal {
        MarketParams memory p = markets[i];
        uint256 collateral = BORROW * 2e36 / IOracle(p.oracle).price();
        deal(p.collateralToken, b, collateral);
        vm.startPrank(b);
        IERC20(p.collateralToken).approve(A.MORPHO, collateral);
        MORPHO.supplyCollateral(p, collateral, b, "");
        MORPHO.borrow(p, BORROW, 0, b, b);
        vm.stopPrank();
    }

    function _borrower(uint256 i) internal returns (address) {
        return makeAddr(string.concat("borrower", vm.toString(i)));
    }
}
