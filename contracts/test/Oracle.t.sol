// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";
import {MockGovernanceToken} from "../src/mocks/MockGovernanceToken.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

/// @notice Oracle validation. v1 read `latestRoundData` and used the answer
///         as-is: no age check, no sign check, no round check.
contract OracleTest is BaseTest {
    function test_RevertsOnStalePrice() public {
        vm.prank(alice);
        vault.deposit(100e18);

        // The feed stops updating for more than an hour.
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVotingVault.StalePrice.selector, block.timestamp - MAX_PRICE_AGE - 1, MAX_PRICE_AGE
            )
        );
        vault.getPrice();
    }

    function test_AcceptsPriceJustWithinMaxAge() public {
        vm.warp(block.timestamp + MAX_PRICE_AGE);
        assertEq(vault.getPrice(), 0.6e18, "exactly at the limit it is still valid");
    }

    function test_RevertsOnNegativePrice() public {
        feed.setAnswer(-1);

        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.InvalidPrice.selector, int256(-1)));
        vault.getPrice();
    }

    function test_RevertsOnZeroPrice() public {
        feed.setAnswer(0);

        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.InvalidPrice.selector, int256(0)));
        vault.getPrice();
    }

    /// @dev v1 did `uint(answer)` on a negative int: instead of reverting it got
    ///      an astronomical number and minted against it.
    function test_NegativePriceCannotBeCastIntoHugeCollateralValue() public {
        vm.prank(alice);
        vault.deposit(100e18);

        feed.setAnswer(-1);

        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.InvalidPrice.selector, int256(-1)));
        vm.prank(alice);
        vault.mint(1e18);
    }

    function test_RevertsOnStuckRound() public {
        // The round advances but the answer stays behind.
        feed.setStuckRound();

        vm.expectRevert();
        vault.getPrice();
    }

    function test_StalePriceBlocksMintAndLiquidation() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 30e18);
        _fundStablecoin(liquidator, 15e18);

        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        vm.expectRevert();
        vm.prank(alice);
        vault.mint(1e18);

        vm.expectRevert();
        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);
    }

    /// @notice Repaying must work even with the oracle down: otherwise a broken
    ///         feed would trap everyone inside their position.
    function test_RepayWorksWithStalePrice() public {
        vm.startPrank(alice);
        vault.depositAndMint(100e18, 30e18);
        stable.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        vm.prank(alice);
        vault.repay(30e18);

        assertEq(vault.debtOf(alice), 0, "you can always repay");
    }

    /// @notice And withdrawing with no debt must not depend on the oracle either.
    function test_WithdrawWithoutDebtWorksWithStalePrice() public {
        vm.prank(alice);
        vault.deposit(100e18);

        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        vm.prank(alice);
        vault.withdraw(100e18);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
    }

    /* ---------------------- decimal normalization ---------------------- */

    function test_PriceNormalizedFrom8Decimals() public view {
        assertEq(vault.getPrice(), 0.6e18, "8 decimals scaled up to 18");
    }

    function test_PriceNormalizedFrom18Decimals() public {
        MockGovernanceToken token18 = new MockGovernanceToken("Gov18", "G18");
        MockPriceFeed feed18 = new MockPriceFeed(18, 1.25e18, "G18 / USD");

        CollateralVotingVault v = new CollateralVotingVault(
            address(token18),
            address(feed18),
            "Stable18",
            "s18",
            MAX_LTV,
            LIQ_THRESHOLD,
            LIQ_BONUS,
            CLOSE_FACTOR,
            MAX_PRICE_AGE,
            owner
        );

        assertEq(v.getPrice(), 1.25e18, "an 18-decimal feed is not rescaled");
    }

    function test_RejectsFeedWithMoreThan18Decimals() public {
        MockGovernanceToken token19 = new MockGovernanceToken("Gov19", "G19");
        MockPriceFeed feed19 = new MockPriceFeed(19, 1e19, "G19 / USD");

        vm.expectRevert(CollateralVotingVault.UnsupportedDecimals.selector);
        new CollateralVotingVault(
            address(token19),
            address(feed19),
            "Stable19",
            "s19",
            MAX_LTV,
            LIQ_THRESHOLD,
            LIQ_BONUS,
            CLOSE_FACTOR,
            MAX_PRICE_AGE,
            owner
        );
    }

    /* ------------------------------ fuzz ------------------------------ */

    /// @notice The mintable ceiling must track the price monotonically.
    function testFuzz_MaxMintableTracksPrice(uint64 rawPrice) public {
        vm.assume(rawPrice > 0);
        feed.setAnswer(int256(uint256(rawPrice)));

        vm.prank(alice);
        vault.deposit(100e18);

        uint256 expected = (100e18 * (uint256(rawPrice) * 1e10) * MAX_LTV) / (WAD * BPS);
        assertEq(vault.maxMintable(alice), expected);
    }
}
