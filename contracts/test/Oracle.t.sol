// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";
import {MockGovernanceToken} from "../src/mocks/MockGovernanceToken.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

/// @notice Validacion del oraculo. La v1 leia `latestRoundData` y usaba la
///         respuesta tal cual: sin comprobar antiguedad, signo ni ronda.
contract OracleTest is BaseTest {
    function test_RevertsOnStalePrice() public {
        vm.prank(alice);
        vault.deposit(100e18);

        // El feed deja de actualizarse durante mas de una hora.
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
        assertEq(vault.getPrice(), 0.6e18, "en el limite exacto todavia es valido");
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

    /// @dev La v1 hacia `uint(answer)` sobre un int negativo: en lugar de
    ///      revertir, obtenia un numero astronomico y emitia contra el.
    function test_NegativePriceCannotBeCastIntoHugeCollateralValue() public {
        vm.prank(alice);
        vault.deposit(100e18);

        feed.setAnswer(-1);

        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.InvalidPrice.selector, int256(-1)));
        vm.prank(alice);
        vault.mint(1e18);
    }

    function test_RevertsOnStuckRound() public {
        // La ronda avanza pero la respuesta se queda en la anterior.
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

    /// @notice Repagar debe funcionar aunque el oraculo este caido: si no,
    ///         un feed roto dejaria a todo el mundo sin poder salir.
    function test_RepayWorksWithStalePrice() public {
        vm.startPrank(alice);
        vault.depositAndMint(100e18, 30e18);
        stable.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        vm.prank(alice);
        vault.repay(30e18);

        assertEq(vault.debtOf(alice), 0, "siempre se puede repagar");
    }

    /// @notice Y retirar sin deuda tampoco debe depender del oraculo.
    function test_WithdrawWithoutDebtWorksWithStalePrice() public {
        vm.prank(alice);
        vault.deposit(100e18);

        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        vm.prank(alice);
        vault.withdraw(100e18);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
    }

    /* --------------------- normalizacion de decimales --------------------- */

    function test_PriceNormalizedFrom8Decimals() public view {
        assertEq(vault.getPrice(), 0.6e18, "8 decimales escalados a 18");
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

        assertEq(v.getPrice(), 1.25e18, "un feed de 18 decimales no se reescala");
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

    /* ------------------------------- fuzz ------------------------------- */

    /// @notice El maximo emitible debe seguir al precio de forma monotona.
    function testFuzz_MaxMintableTracksPrice(uint64 rawPrice) public {
        vm.assume(rawPrice > 0);
        feed.setAnswer(int256(uint256(rawPrice)));

        vm.prank(alice);
        vault.deposit(100e18);

        uint256 expected = (100e18 * (uint256(rawPrice) * 1e10) * MAX_LTV) / (WAD * BPS);
        assertEq(vault.maxMintable(alice), expected);
    }
}
