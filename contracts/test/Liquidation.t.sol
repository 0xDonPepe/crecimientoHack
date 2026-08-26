// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";

/// @notice Liquidations. v1 had none: a price drop left the stablecoin unbacked
///         and nobody could do anything about it.
contract LiquidationTest is BaseTest {
    /// @dev Standard position: 100 tokens at 0.60 USD, 30 gUSD of debt (50% LTV).
    function _openAlicePosition() internal {
        vm.prank(alice);
        vault.depositAndMint(100e18, 30e18);
    }

    function test_HealthyPositionIsNotLiquidatable() public {
        _openAlicePosition();

        // 60 USD * 0.75 / 30 = 1.5
        assertEq(vault.healthFactor(alice), 1.5e18);
        assertFalse(vault.isLiquidatable(alice));

        _fundStablecoin(liquidator, 15e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.PositionHealthy.selector, 1.5e18));
        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);
    }

    function test_PositionBecomesLiquidatableAfterPriceDrop() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);

        // At 0.35 USD: 35 USD of collateral * 0.75 = 26.25, against 30 of debt.
        feed.setAnswer(0.35e8);

        assertEq(vault.healthFactor(alice), 0.875e18);
        assertTrue(vault.isLiquidatable(alice));
    }

    function test_LiquidateSeizesCollateralPlusBonus() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);
        feed.setAnswer(0.35e8);

        uint256 tokensBefore = token.balanceOf(liquidator);

        vm.prank(liquidator);
        uint256 seized = vault.liquidate(alice, 15e18);

        // 15 USD covered * 1.10 bonus / 0.35 per token.
        uint256 expected = (15e18 * 11_000 * WAD) / (BPS * 0.35e18);
        assertEq(seized, expected, "collateral seized with the 10% bonus");
        assertEq(token.balanceOf(liquidator) - tokensBefore, seized, "the liquidator receives the tokens");

        // The bonus is real: they take out more value than they paid in.
        uint256 seizedUsd = (seized * 0.35e18) / WAD;
        assertGt(seizedUsd, 15e18, "the liquidator comes out ahead");
        // One wei of round-down: integer division favours the protocol, never
        // the liquidator. The direction of the rounding is asserted, not just
        // its magnitude.
        assertApproxEqAbs(seizedUsd, 16.5e18, 1, "roughly a 10% bonus");
        assertLe(seizedUsd, 16.5e18, "rounding can never favour the liquidator");
    }

    function test_LiquidateBurnsStablecoinAndReducesDebt() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);
        feed.setAnswer(0.35e8);

        uint256 supplyBefore = stable.totalSupply();

        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);

        assertEq(vault.debtOf(alice), 15e18, "debt falls by what was covered");
        assertEq(stable.balanceOf(liquidator), 0, "the liquidator spent their stablecoin");
        assertEq(stable.totalSupply(), supplyBefore - 15e18, "supply contracts");
        assertEq(vault.totalDebt(), stable.totalSupply(), "accounting and supply agree");
    }

    function test_LiquidationImprovesHealthFactor() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);
        feed.setAnswer(0.35e8);

        uint256 hfBefore = vault.healthFactor(alice);

        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);

        assertGt(vault.healthFactor(alice), hfBefore, "liquidating should heal the position");
    }

    function test_CloseFactorCapsSingleLiquidation() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 30e18);
        feed.setAnswer(0.35e8);

        // Tries to cover the whole debt; the close factor halves it.
        vm.prank(liquidator);
        vault.liquidate(alice, 30e18);

        assertEq(vault.debtOf(alice), 15e18, "only 50% could be covered");
        assertEq(stable.balanceOf(liquidator), 15e18, "the rest of their stablecoin is untouched");
    }

    function test_InsolventPositionSeizesAllRemainingCollateral() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);

        // Brutal crash: 100 tokens at 0.10 USD = 10 USD against 30 of debt.
        feed.setAnswer(0.1e8);

        vm.prank(liquidator);
        uint256 seized = vault.liquidate(alice, 15e18);

        assertEq(seized, 100e18, "all available collateral is seized");
        assertEq(vault.collateralOf(alice), 0);
        assertEq(vault.debtOf(alice), 15e18, "bad debt is recognized, not reverted");
        assertEq(token.balanceOf(vault.accountOf(alice)), 0);
    }

    function test_CannotLiquidateWithoutDebt() public {
        vm.prank(alice);
        vault.deposit(100e18);

        vm.expectRevert(CollateralVotingVault.NoDebt.selector);
        vm.prank(liquidator);
        vault.liquidate(alice, 1e18);
    }

    function test_LiquidationEmitsEvent() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);
        feed.setAnswer(0.35e8);

        uint256 expected = (15e18 * 11_000 * WAD) / (BPS * 0.35e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit CollateralVotingVault.Liquidated(liquidator, alice, 15e18, expected);

        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);
    }

    /// @notice Seized collateral stops contributing voting power to the borrower.
    function test_LiquidationMovesVotingPowerAway() public {
        vm.prank(alice);
        token.delegate(alice);
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);

        uint256 votesBefore = token.getVotes(alice);

        feed.setAnswer(0.35e8);
        vm.prank(liquidator);
        uint256 seized = vault.liquidate(alice, 15e18);

        assertEq(token.getVotes(alice), votesBefore - seized, "loses the votes of the seized collateral");
    }

    /* ------------------------- salvage regime ------------------------- */

    /// @notice The exact boundary past which liquidating stops healing.
    /// @dev Derivation. With V = collateral value, D = debt, T = liquidation
    ///      threshold and b = bonus, covering `d` leaves V' = V - d(1+b) and
    ///      D' = D - d.
    ///
    ///          HF' > HF  <=>  (V - d(1+b)) / (D - d)  >  V / D
    ///                    <=>  DV - Dd(1+b) > VD - Vd
    ///                    <=>  V > D(1+b)
    ///
    ///      In other words, liquidating improves the health factor only while
    ///      the collateral still covers the debt plus the bonus. In health
    ///      factor terms that is HF > T(1+b), here 0.75 * 1.10 = 0.825. Below
    ///      that, every liquidation extracts more value than it cancels and the
    ///      position sinks further: it is bad debt, and all that is left is to
    ///      let liquidators drain it. Aave and Compound behave the same way; it
    ///      is not a flaw in this contract, but it is a limit worth knowing when
    ///      choosing the bonus.
    function SALVAGE_THRESHOLD() public pure returns (uint256) {
        return (LIQ_THRESHOLD * (BPS + LIQ_BONUS) * WAD) / (BPS * BPS); // 0.825e18
    }

    function test_AboveSalvageThresholdLiquidationHeals() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);

        // 0.35 gives HF 0.875, above 0.825.
        feed.setAnswer(0.35e8);
        assertGt(vault.healthFactor(alice), SALVAGE_THRESHOLD());

        uint256 hfBefore = vault.healthFactor(alice);
        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);

        assertGt(vault.healthFactor(alice), hfBefore, "above the boundary, liquidating heals");
    }

    function test_BelowSalvageThresholdPositionIsBeyondSaving() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);

        // 0.30 gives HF 0.75, below 0.825.
        feed.setAnswer(0.3e8);
        assertLt(vault.healthFactor(alice), SALVAGE_THRESHOLD());

        uint256 hfBefore = vault.healthFactor(alice);
        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);

        // Documented on purpose: here the health factor gets WORSE.
        assertLt(vault.healthFactor(alice), hfBefore, "below the boundary there is no rescue");
        assertLt(vault.debtOf(alice), 30e18, "but the bad debt does shrink");
    }

    /* ------------------------------ fuzz ------------------------------ */

    /// @notice Properties that must hold for ANY liquidation.
    function testFuzz_LiquidationInvariants(uint256 dropBps, uint256 debtToCover) public {
        dropBps = bound(dropBps, 4_100, 9_000); // a 41% to 90% crash
        debtToCover = bound(debtToCover, 1, 30e18);

        _openAlicePosition();
        _fundStablecoin(liquidator, 30e18);

        int256 newPrice = int256((uint256(uint256(INITIAL_PRICE)) * (BPS - dropBps)) / BPS);
        vm.assume(newPrice > 0);
        feed.setAnswer(newPrice);

        if (!vault.isLiquidatable(alice)) return;

        uint256 hfBefore = vault.healthFactor(alice);
        uint256 debtBefore = vault.debtOf(alice);
        uint256 collateralBefore = vault.collateralOf(alice);
        uint256 supplyBefore = stable.totalSupply();

        vm.prank(liquidator);
        uint256 seized = vault.liquidate(alice, debtToCover);

        uint256 covered = debtBefore - vault.debtOf(alice);

        assertLe(vault.debtOf(alice), debtBefore, "debt never rises");
        assertLe(vault.collateralOf(alice), collateralBefore, "collateral never rises");
        assertLe(covered, (debtBefore * CLOSE_FACTOR) / BPS, "the close factor is respected");
        assertEq(stable.totalSupply(), supplyBefore - covered, "exactly what was covered gets burned");
        assertEq(vault.totalDebt(), stable.totalSupply(), "book debt and supply agree");

        // The liquidator can never take more than covered debt plus bonus.
        uint256 seizedUsd = (seized * vault.getPrice()) / WAD;
        assertLe(seizedUsd, (covered * (BPS + LIQ_BONUS)) / BPS, "the bonus is bounded");

        // And above the salvage boundary, liquidating always heals.
        // The 1e9 slack (1e-9 relative) absorbs integer-division dust: covering
        // 1 wei of debt can move the HF down by 1 wei without that being a
        // regression. Any real failure is on the order of 1e17.
        if (hfBefore > SALVAGE_THRESHOLD() && vault.collateralOf(alice) > 0 && vault.debtOf(alice) > 0) {
            assertGe(vault.healthFactor(alice) + 1e9, hfBefore, "above the boundary the HF improves");
        }
    }
}
