// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";

/// @notice Liquidaciones. La v1 no tenia ninguna: una caida de precio dejaba a
///         la stablecoin sin respaldo y nadie podia hacer nada al respecto.
contract LiquidationTest is BaseTest {
    /// @dev Posicion estandar: 100 tokens a 0.60 USD, 30 gUSD de deuda (LTV 50%).
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

        // A 0.35 USD: 35 USD de colateral * 0.75 = 26.25, contra 30 de deuda.
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

        // 15 USD cubiertos * 1.10 de bono / 0.35 por token.
        uint256 expected = (15e18 * 11_000 * WAD) / (BPS * 0.35e18);
        assertEq(seized, expected, "colateral incautado con bono del 10%");
        assertEq(token.balanceOf(liquidator) - tokensBefore, seized, "el liquidador recibe los tokens");

        // El bono es real: se lleva mas valor del que pago.
        uint256 seizedUsd = (seized * 0.35e18) / WAD;
        assertGt(seizedUsd, 15e18, "el liquidador sale ganando");
        // Redondeo a la baja de 1 wei: la division entera favorece al protocolo,
        // nunca al liquidador. Se comprueba el sentido del redondeo, no solo la magnitud.
        assertApproxEqAbs(seizedUsd, 16.5e18, 1, "aproximadamente el 10% de bono");
        assertLe(seizedUsd, 16.5e18, "el redondeo nunca puede favorecer al liquidador");
    }

    function test_LiquidateBurnsStablecoinAndReducesDebt() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);
        feed.setAnswer(0.35e8);

        uint256 supplyBefore = stable.totalSupply();

        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);

        assertEq(vault.debtOf(alice), 15e18, "la deuda baja en lo cubierto");
        assertEq(stable.balanceOf(liquidator), 0, "el liquidador gasto su stablecoin");
        assertEq(stable.totalSupply(), supplyBefore - 15e18, "la oferta se contrae");
        assertEq(vault.totalDebt(), stable.totalSupply(), "contabilidad y oferta cuadran");
    }

    function test_LiquidationImprovesHealthFactor() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);
        feed.setAnswer(0.35e8);

        uint256 hfBefore = vault.healthFactor(alice);

        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);

        assertGt(vault.healthFactor(alice), hfBefore, "liquidar debe sanear la posicion");
    }

    function test_CloseFactorCapsSingleLiquidation() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 30e18);
        feed.setAnswer(0.35e8);

        // Intenta cubrir toda la deuda; el close factor lo recorta a la mitad.
        vm.prank(liquidator);
        vault.liquidate(alice, 30e18);

        assertEq(vault.debtOf(alice), 15e18, "solo se pudo cubrir el 50%");
        assertEq(stable.balanceOf(liquidator), 15e18, "el resto de su stablecoin sigue intacto");
    }

    function test_InsolventPositionSeizesAllRemainingCollateral() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);

        // Caida brutal: 100 tokens a 0.10 USD = 10 USD contra 30 de deuda.
        feed.setAnswer(0.1e8);

        vm.prank(liquidator);
        uint256 seized = vault.liquidate(alice, 15e18);

        assertEq(seized, 100e18, "se incauta todo el colateral disponible");
        assertEq(vault.collateralOf(alice), 0);
        assertEq(vault.debtOf(alice), 15e18, "queda deuda mala reconocida, no un revert");
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

    /// @notice El colateral liquidado deja de aportar poder de voto al deudor.
    function test_LiquidationMovesVotingPowerAway() public {
        vm.prank(alice);
        token.delegate(alice);
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);

        uint256 votesBefore = token.getVotes(alice);

        feed.setAnswer(0.35e8);
        vm.prank(liquidator);
        uint256 seized = vault.liquidate(alice, 15e18);

        assertEq(token.getVotes(alice), votesBefore - seized, "pierde el voto del colateral incautado");
    }

    /* ------------------------ regimen de rescate ------------------------ */

    /// @notice Frontera exacta a partir de la cual liquidar deja de sanear.
    /// @dev Derivacion. Con V = valor del colateral, D = deuda, T = umbral de
    ///      liquidacion y b = bono, liquidar `d` deja V' = V - d(1+b) y D' = D - d.
    ///
    ///          HF' > HF  <=>  (V - d(1+b)) / (D - d)  >  V / D
    ///                    <=>  DV - Dd(1+b) > VD - Vd
    ///                    <=>  V > D(1+b)
    ///
    ///      Es decir, liquidar mejora el health factor solo si el colateral aun
    ///      cubre la deuda mas el bono. En health factor eso es HF > T(1+b),
    ///      aqui 0.75 * 1.10 = 0.825. Por debajo, cada liquidacion extrae mas
    ///      valor del que cancela y la posicion se hunde mas: es deuda mala y lo
    ///      unico que queda es dejar que los liquidadores la vacien. Aave y
    ///      Compound se comportan igual; no es un defecto de este contrato, pero
    ///      si un limite que hay que conocer al elegir el bono.
    function SALVAGE_THRESHOLD() public pure returns (uint256) {
        return (LIQ_THRESHOLD * (BPS + LIQ_BONUS) * WAD) / (BPS * BPS); // 0.825e18
    }

    function test_AboveSalvageThresholdLiquidationHeals() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);

        // 0.35 da HF 0.875, por encima de 0.825.
        feed.setAnswer(0.35e8);
        assertGt(vault.healthFactor(alice), SALVAGE_THRESHOLD());

        uint256 hfBefore = vault.healthFactor(alice);
        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);

        assertGt(vault.healthFactor(alice), hfBefore, "por encima de la frontera, liquidar sanea");
    }

    function test_BelowSalvageThresholdPositionIsBeyondSaving() public {
        _openAlicePosition();
        _fundStablecoin(liquidator, 15e18);

        // 0.30 da HF 0.75, por debajo de 0.825.
        feed.setAnswer(0.3e8);
        assertLt(vault.healthFactor(alice), SALVAGE_THRESHOLD());

        uint256 hfBefore = vault.healthFactor(alice);
        vm.prank(liquidator);
        vault.liquidate(alice, 15e18);

        // Documentado a proposito: aqui el health factor EMPEORA.
        assertLt(vault.healthFactor(alice), hfBefore, "por debajo de la frontera ya no hay rescate");
        assertLt(vault.debtOf(alice), 30e18, "pero la deuda mala si se reduce");
    }

    /* ------------------------------- fuzz ------------------------------- */

    /// @notice Propiedades que deben cumplirse en CUALQUIER liquidacion.
    function testFuzz_LiquidationInvariants(uint256 dropBps, uint256 debtToCover) public {
        dropBps = bound(dropBps, 4_100, 9_000); // caida del 41% al 90%
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

        assertLe(vault.debtOf(alice), debtBefore, "la deuda nunca sube");
        assertLe(vault.collateralOf(alice), collateralBefore, "el colateral nunca sube");
        assertLe(covered, (debtBefore * CLOSE_FACTOR) / BPS, "se respeta el close factor");
        assertEq(stable.totalSupply(), supplyBefore - covered, "se quema exactamente lo cubierto");
        assertEq(vault.totalDebt(), stable.totalSupply(), "deuda contable y oferta cuadran");

        // El liquidador nunca puede llevarse mas que deuda cubierta + bono.
        uint256 seizedUsd = (seized * vault.getPrice()) / WAD;
        assertLe(seizedUsd, (covered * (BPS + LIQ_BONUS)) / BPS, "el bono esta acotado");

        // Y por encima de la frontera de rescate, liquidar siempre sanea.
        // La holgura de 1e9 (1e-9 relativo) absorbe el polvo de la division
        // entera: cubrir 1 wei de deuda puede mover el HF 1 wei a la baja sin
        // que eso sea una regresion. Cualquier fallo real es de orden 1e17.
        if (hfBefore > SALVAGE_THRESHOLD() && vault.collateralOf(alice) > 0 && vault.debtOf(alice) > 0) {
            assertGe(vault.healthFactor(alice) + 1e9, hfBefore, "sobre la frontera, el HF mejora");
        }
    }
}
