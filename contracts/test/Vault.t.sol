// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";
import {DelegationAccount} from "../src/DelegationAccount.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Mecanica completa del CDP: deposito, emision, repago, retiro,
///         delegacion, administracion y pausa.
contract VaultTest is BaseTest {
    /* ----------------------------- deposito ----------------------------- */

    function test_DepositCreatesDeterministicAccount() public {
        address predicted = vault.predictAccountAddress(alice);

        vm.prank(alice);
        vault.deposit(10e18);

        assertEq(vault.accountOf(alice), predicted, "la direccion es predecible antes de existir");
    }

    function test_SecondDepositReusesSameAccount() public {
        vm.startPrank(alice);
        vault.deposit(10e18);
        address first = vault.accountOf(alice);
        vault.deposit(10e18);
        vm.stopPrank();

        assertEq(vault.accountOf(alice), first, "no se despliega una cuenta nueva");
    }

    function test_OpenAccountBeforeDepositing() public {
        vm.prank(alice);
        address account = vault.openAccount();

        assertEq(vault.accountOf(alice), account);
        assertEq(vault.collateralOf(alice), 0);
        assertEq(DelegationAccount(account).owner(), alice);
    }

    function test_DepositRevertsOnZero() public {
        vm.expectRevert(CollateralVotingVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.deposit(0);
    }

    function test_DepositRevertsWithoutAllowance() public {
        vm.prank(alice);
        token.approve(address(vault), 0);

        vm.expectRevert();
        vm.prank(alice);
        vault.deposit(1e18);
    }

    function test_TotalsTrackAllPositions() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 20e18);
        vm.prank(bob);
        vault.depositAndMint(200e18, 50e18);

        assertEq(vault.totalCollateral(), 300e18);
        assertEq(vault.totalDebt(), 70e18);
        assertEq(stable.totalSupply(), 70e18, "la oferta iguala a la deuda");
    }

    /* ------------------------------ emision ------------------------------ */

    function test_MintUpToExactLimit() public {
        vm.startPrank(alice);
        vault.deposit(100e18);
        vault.mint(vault.maxMintable(alice));
        vm.stopPrank();

        assertEq(vault.debtOf(alice), 30e18);
        assertEq(vault.maxMintable(alice), 0);
        assertEq(vault.healthFactor(alice), 1.5e18);
    }

    function test_MintInSeveralSteps() public {
        vm.startPrank(alice);
        vault.deposit(100e18);
        vault.mint(10e18);
        vault.mint(10e18);
        vault.mint(10e18);
        vm.stopPrank();

        assertEq(vault.debtOf(alice), 30e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.ExceedsMaxLtv.selector, 30e18 + 1e18, 30e18));
        vm.prank(alice);
        vault.mint(1e18);
    }

    function test_MintRevertsWithoutCollateral() public {
        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.ExceedsMaxLtv.selector, 1e18, 0));
        vm.prank(alice);
        vault.mint(1e18);
    }

    function test_RisingPriceUnlocksMoreMinting() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 30e18);
        assertEq(vault.maxMintable(alice), 0);

        feed.setAnswer(1.2e8); // el colateral duplica su valor

        assertEq(vault.maxMintable(alice), 30e18, "ahora puede emitir mas");
        assertEq(vault.healthFactor(alice), 3e18);
    }

    /* ------------------------------- repago ------------------------------ */

    function test_RepayPartial() public {
        vm.startPrank(alice);
        vault.depositAndMint(100e18, 30e18);
        stable.approve(address(vault), type(uint256).max);
        vault.repay(10e18);
        vm.stopPrank();

        assertEq(vault.debtOf(alice), 20e18);
        assertEq(stable.balanceOf(alice), 20e18);
        assertEq(stable.totalSupply(), 20e18);
    }

    function test_RepayMaxUintClearsWholeDebt() public {
        vm.startPrank(alice);
        vault.depositAndMint(100e18, 30e18);
        uint256 repaid = vault.repay(type(uint256).max);
        vm.stopPrank();

        assertEq(repaid, 30e18, "se ajusta a la deuda real");
        assertEq(vault.debtOf(alice), 0);
        assertEq(stable.balanceOf(alice), 0);
    }

    function test_RepayForSomeoneElse() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 30e18);

        _fundStablecoin(bob, 30e18);

        vm.prank(bob);
        vault.repayFor(alice, 30e18);

        assertEq(vault.debtOf(alice), 0, "un tercero puede rescatar la posicion");
        assertEq(vault.collateralOf(alice), 100e18, "sin tocar su colateral");
    }

    function test_RepayRevertsWithoutDebt() public {
        vm.expectRevert(CollateralVotingVault.NoDebt.selector);
        vm.prank(alice);
        vault.repay(1e18);
    }

    /* ------------------------------- retiro ------------------------------ */

    function test_WithdrawEverythingWhenDebtFree() public {
        vm.startPrank(alice);
        vault.deposit(100e18);
        vault.withdraw(100e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(vault.collateralOf(alice), 0);
    }

    function test_WithdrawPartialKeepingHealthy() public {
        vm.startPrank(alice);
        vault.depositAndMint(100e18, 15e18);
        // 15 gUSD de deuda necesitan 50 tokens al 50% LTV; puede sacar 50.
        vault.withdraw(50e18);
        vm.stopPrank();

        assertEq(vault.collateralOf(alice), 50e18);
        assertEq(vault.healthFactor(alice), 1.5e18);
    }

    function test_WithdrawRevertsIfItBreaksLtv() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 30e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.ExceedsMaxLtv.selector, 30e18, 29.7e18));
        vm.prank(alice);
        vault.withdraw(1e18);
    }

    function test_WithdrawRevertsAboveBalance() public {
        vm.prank(alice);
        vault.deposit(10e18);

        vm.expectRevert(CollateralVotingVault.InsufficientCollateral.selector);
        vm.prank(alice);
        vault.withdraw(11e18);
    }

    /* ----------------------------- delegacion ---------------------------- */

    function test_DelegateToThirdPartyWhileBorrowing() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 30e18);

        vm.prank(alice);
        vault.delegate(bob);

        assertEq(vault.delegateOf(alice), bob);
        assertEq(token.getVotes(bob), 100e18, "bob vota con el colateral de alice");
        assertEq(vault.debtOf(alice), 30e18, "y alice conserva su deuda y su stablecoin");
        assertEq(stable.balanceOf(alice), 30e18);
    }

    function test_DelegateCanBeChanged() public {
        vm.startPrank(alice);
        vault.deposit(100e18);
        vault.delegate(bob);
        vault.delegate(carol);
        vm.stopPrank();

        assertEq(token.getVotes(bob), 0);
        assertEq(token.getVotes(carol), 100e18);
    }

    function test_DelegateRevertsWithoutAccount() public {
        vm.expectRevert(CollateralVotingVault.NoAccount.selector);
        vm.prank(alice);
        vault.delegate(bob);
    }

    function test_WithdrawReducesDelegatedVotingPower() public {
        vm.startPrank(alice);
        vault.deposit(100e18);
        vault.delegate(bob);
        vault.withdraw(40e18);
        vm.stopPrank();

        assertEq(token.getVotes(bob), 60e18, "el voto sigue al colateral que queda");
    }

    function test_ImplementationCannotBeInitialized() public {
        DelegationAccount impl = DelegationAccount(vault.accountImplementation());

        vm.expectRevert(DelegationAccount.AlreadyInitialized.selector);
        impl.initialize(address(this), alice, address(token));
    }

    /* --------------------------- administracion -------------------------- */

    function test_OnlyOwnerSetsRiskParameters() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.setRiskParameters(4_000, 7_000, 500, 5_000);

        vm.prank(owner);
        vault.setRiskParameters(4_000, 7_000, 500, 5_000);

        assertEq(vault.maxLtvBps(), 4_000);
        assertEq(vault.liquidationThresholdBps(), 7_000);
    }

    function test_RejectsLtvAboveLiquidationThreshold() public {
        vm.expectRevert(CollateralVotingVault.InvalidParameters.selector);
        vm.prank(owner);
        vault.setRiskParameters(8_000, 7_500, 1_000, 5_000);
    }

    function test_RejectsExcessiveLiquidationBonus() public {
        vm.expectRevert(CollateralVotingVault.InvalidParameters.selector);
        vm.prank(owner);
        vault.setRiskParameters(5_000, 7_500, 2_001, 5_000);
    }

    function test_RejectsOutOfRangePriceAge() public {
        vm.expectRevert(CollateralVotingVault.InvalidParameters.selector);
        vm.prank(owner);
        vault.setMaxPriceAge(1 seconds);

        vm.expectRevert(CollateralVotingVault.InvalidParameters.selector);
        vm.prank(owner);
        vault.setMaxPriceAge(8 days);
    }

    function test_OwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(alice);

        assertEq(vault.owner(), owner, "no cambia hasta que el destinatario acepta");

        vm.prank(alice);
        vault.acceptOwnership();

        assertEq(vault.owner(), alice);
    }

    /* -------------------------------- pausa ------------------------------- */

    function test_PauseBlocksDepositAndMint() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        vault.deposit(1e18);
    }

    /// @notice Pausar no puede secuestrar el colateral de nadie.
    function test_PauseStillAllowsRepayAndWithdraw() public {
        vm.startPrank(alice);
        vault.depositAndMint(100e18, 30e18);
        stable.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        vault.repay(30e18);
        vault.withdraw(100e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), INITIAL_BALANCE, "siempre hay salida");
    }

    function test_UnpauseRestoresDeposits() public {
        vm.startPrank(owner);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1e18);

        assertEq(vault.collateralOf(alice), 1e18);
    }

    /* -------------------------------- fuzz -------------------------------- */

    /// @notice Cualquier ciclo completo devuelve exactamente el colateral.
    function testFuzz_RoundTripIsLossless(uint256 collateral, uint256 mintPct) public {
        collateral = bound(collateral, 1e15, INITIAL_BALANCE);
        mintPct = bound(mintPct, 0, 100);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        vault.deposit(collateral);
        uint256 toMint = (vault.maxMintable(alice) * mintPct) / 100;
        if (toMint > 0) {
            vault.mint(toMint);
            stable.approve(address(vault), type(uint256).max);
            vault.repay(type(uint256).max);
        }
        vault.withdraw(collateral);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), balanceBefore, "el usuario recupera todo");
        assertEq(vault.debtOf(alice), 0);
        assertEq(stable.totalSupply(), 0);
    }

    /// @notice Emitir el maximo deja siempre la posicion justo en el LTV, sana.
    function testFuzz_MaxMintLeavesPositionHealthy(uint256 collateral, uint64 rawPrice) public {
        collateral = bound(collateral, 1e18, INITIAL_BALANCE);
        vm.assume(rawPrice > 1e6); // por encima de 0.01 USD
        feed.setAnswer(int256(uint256(rawPrice)));

        vm.startPrank(alice);
        vault.deposit(collateral);
        uint256 toMint = vault.maxMintable(alice);
        vm.assume(toMint > 0);
        vault.mint(toMint);
        vm.stopPrank();

        assertFalse(vault.isLiquidatable(alice), "emitir el maximo nunca crea una posicion liquidable");
        assertGe(vault.healthFactor(alice), WAD);
    }

    /// @notice El poder de voto total del usuario es invariante al deposito.
    function testFuzz_VotingPowerPreserved(uint256 collateral) public {
        collateral = bound(collateral, 1e15, INITIAL_BALANCE);

        vm.prank(alice);
        token.delegate(alice);
        uint256 votesBefore = token.getVotes(alice);

        vm.prank(alice);
        vault.deposit(collateral);

        assertEq(token.getVotes(alice), votesBefore, "depositar jamas cuesta poder de voto");
    }
}
