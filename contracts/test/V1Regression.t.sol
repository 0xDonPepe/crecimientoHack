// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";
import {DelegationAccount} from "../src/DelegationAccount.sol";
import {GovStablecoin} from "../src/GovStablecoin.sol";

/// @title V1Regression
/// @notice Un test por cada defecto encontrado en la version del hackathon.
/// @dev Cada `test_` documenta que hacia la v1 y comprueba que ya no ocurre.
///      Sirven de red de seguridad y, sobre todo, de bitacora de la revision.
contract V1RegressionTest is BaseTest {
    /* ---------------------------------------------------------------- *
     * BUG 1 - El colateral se quedaba en el vault, no en la cuenta de
     * delegacion, asi que la delegacion delegaba un balance de cero y el
     * poder de voto del colateral simplemente desaparecia.
     * ---------------------------------------------------------------- */

    function test_Bug1_CollateralLandsInDelegationAccountNotVault() public {
        vm.prank(alice);
        vault.deposit(100e18);

        address account = vault.accountOf(alice);

        assertEq(token.balanceOf(account), 100e18, "el colateral debe vivir en la cuenta del usuario");
        assertEq(token.balanceOf(address(vault)), 0, "el vault no debe custodiar colateral");
    }

    function test_Bug1_DepositingDoesNotCostVotingPower() public {
        // Alice se auto-delega, como haria cualquier holder que vota.
        vm.prank(alice);
        token.delegate(alice);

        uint256 votesBefore = token.getVotes(alice);
        assertEq(votesBefore, INITIAL_BALANCE);

        vm.prank(alice);
        vault.depositAndMint(400e18, 100e18);

        // Esta es la tesis entera del protocolo: deposita, se endeuda, y su
        // poder de voto no se movio ni un wei. En la v1 caia a 600e18.
        assertEq(token.getVotes(alice), votesBefore, "depositar no debe costar poder de voto");
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 400e18, "y aun asi los tokens salieron de su wallet");
    }

    function test_Bug1_DelegationAccountSelfDelegatesToOwner() public {
        vm.prank(alice);
        vault.deposit(100e18);

        assertEq(vault.delegateOf(alice), alice, "la cuenta debe delegar al dueno de entrada");
    }

    /* ---------------------------------------------------------------- *
     * BUG 2 - La stablecoin se emitia a la cuenta de delegacion, que no
     * tenia ninguna funcion para moverla. Quedaba atrapada para siempre y
     * el usuario nunca la veia.
     * ---------------------------------------------------------------- */

    function test_Bug2_StablecoinIsMintedToTheUser() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 20e18);

        address account = vault.accountOf(alice);

        assertEq(stable.balanceOf(alice), 20e18, "la stablecoin es del usuario");
        assertEq(stable.balanceOf(account), 0, "la cuenta de delegacion no debe retenerla");
    }

    function test_Bug2_UserCanActuallySpendTheStablecoin() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 20e18);

        // Lo que la v1 hacia imposible: usarla en DeFi.
        vm.prank(alice);
        stable.transfer(bob, 20e18);

        assertEq(stable.balanceOf(bob), 20e18);
    }

    /* ---------------------------------------------------------------- *
     * BUG 3 - Error de escala de 1e18. La v1 multiplicaba precio (18 dec)
     * por cantidad (18 dec) y emitia el resultado de 36 decimales como si
     * fuese de 18, emitiendo 1e18 veces de mas.
     * ---------------------------------------------------------------- */

    function test_Bug3_MintAmountHasCorrectScale() public {
        // 100 tokens a 0.60 USD = 60 USD de colateral, 50% LTV = 30 gUSD.
        vm.prank(alice);
        vault.deposit(100e18);

        assertEq(vault.collateralValue(alice), 60e18, "valor del colateral en USD con 18 decimales");
        assertEq(vault.maxMintable(alice), 30e18, "maximo emitible correcto");

        vm.prank(alice);
        vault.mint(30e18);

        assertEq(stable.balanceOf(alice), 30e18);
        // La v1 habria emitido 30e36. Se comprueba explicitamente.
        assertLt(stable.balanceOf(alice), 30e36, "la v1 emitia 1e18 veces de mas");
    }

    function test_Bug3_CannotMintMoreThanLtvAllows() public {
        vm.prank(alice);
        vault.deposit(100e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.ExceedsMaxLtv.selector, 30e18 + 1, 30e18));
        vm.prank(alice);
        vault.mint(30e18 + 1);
    }

    /* ---------------------------------------------------------------- *
     * BUG 4 - `createUserDelegationAccount` era `public` y aceptaba
     * cualquier direccion, asi que cualquiera podia sobrescribir la cuenta
     * de delegacion de otro usuario.
     * ---------------------------------------------------------------- */

    function test_Bug4_AccountCreationIsNotHijackable() public {
        vm.prank(alice);
        vault.deposit(100e18);
        address aliceAccount = vault.accountOf(alice);

        // Bob no tiene forma de crear ni reemplazar la cuenta de alice: la unica
        // via es `openAccount`, que siempre opera sobre msg.sender.
        vm.prank(bob);
        address bobAccount = vault.openAccount();

        assertTrue(bobAccount != aliceAccount, "cada usuario tiene su propia cuenta");
        assertEq(vault.accountOf(alice), aliceAccount, "la cuenta de alice no cambio");
    }

    function test_Bug4_AccountCannotBeReinitialized() public {
        vm.prank(alice);
        vault.deposit(100e18);

        DelegationAccount account = DelegationAccount(vault.accountOf(alice));

        vm.expectRevert(DelegationAccount.AlreadyInitialized.selector);
        vm.prank(bob);
        account.initialize(bob, bob, address(token));
    }

    function test_Bug4_OnlyVaultCanReleaseCollateral() public {
        vm.prank(alice);
        vault.deposit(100e18);

        DelegationAccount account = DelegationAccount(vault.accountOf(alice));

        vm.expectRevert(DelegationAccount.OnlyVault.selector);
        vm.prank(bob);
        account.releaseCollateral(bob, 100e18);
    }

    function test_Bug4_OnlyOwnerCanDelegateTheirCollateral() public {
        vm.prank(alice);
        vault.deposit(100e18);

        DelegationAccount account = DelegationAccount(vault.accountOf(alice));

        vm.expectRevert(DelegationAccount.NotAuthorized.selector);
        vm.prank(bob);
        account.delegate(bob);
    }

    /* ---------------------------------------------------------------- *
     * BUG 5 - `userLockedTokens[msg.sender] = amount` sobrescribia en vez
     * de acumular, asi que el segundo deposito borraba el primero.
     * ---------------------------------------------------------------- */

    function test_Bug5_MultipleDepositsAccumulate() public {
        vm.startPrank(alice);
        vault.deposit(100e18);
        vault.deposit(50e18);
        vault.deposit(25e18);
        vm.stopPrank();

        assertEq(vault.collateralOf(alice), 175e18, "los depositos se suman");
        assertEq(token.balanceOf(vault.accountOf(alice)), 175e18);
    }

    /* ---------------------------------------------------------------- *
     * BUG 6 - No existia salida. `returnGovernanceTokens` estaba escrita
     * pero nadie la llamaba nunca: el colateral entraba y no salia.
     * ---------------------------------------------------------------- */

    function test_Bug6_FullRoundTripReturnsAllCollateral() public {
        uint256 balanceBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        vault.depositAndMint(100e18, 30e18);
        stable.approve(address(vault), type(uint256).max);
        vault.repayAndWithdraw(30e18, 100e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), balanceBefore, "recupera todo su colateral");
        assertEq(vault.debtOf(alice), 0, "sin deuda");
        assertEq(vault.collateralOf(alice), 0, "sin colateral bloqueado");
        assertEq(stable.totalSupply(), 0, "la stablecoin emitida se quemo");
    }

    /* ---------------------------------------------------------------- *
     * BUG 7 - `depositAndMintStablecoin` declaraba `returns(uint)` y nunca
     * retornaba: siempre devolvia 0 en silencio.
     * ---------------------------------------------------------------- */

    function test_Bug7_ReturnValuesAreReal() public {
        vm.startPrank(alice);
        vault.depositAndMint(100e18, 30e18);
        stable.approve(address(vault), type(uint256).max);

        uint256 repaid = vault.repay(10e18);
        vm.stopPrank();

        assertEq(repaid, 10e18, "repay devuelve lo efectivamente repagado");
    }

    /* ---------------------------------------------------------------- *
     * BUG 8 - Cero eventos en todo el sistema: nada indexable.
     * ---------------------------------------------------------------- */

    function test_Bug8_OperationsEmitEvents() public {
        address predicted = vault.predictAccountAddress(alice);

        vm.expectEmit(true, true, false, true, address(vault));
        emit CollateralVotingVault.AccountOpened(alice, predicted);
        vm.expectEmit(true, true, false, true, address(vault));
        emit CollateralVotingVault.Deposited(alice, predicted, 100e18);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CollateralVotingVault.Minted(alice, 30e18, 30e18);

        vm.prank(alice);
        vault.depositAndMint(100e18, 30e18);
    }

    /* ---------------------------------------------------------------- *
     * BUG 9 - La stablecoin de la v1 no tenia `burn`, asi que aunque se
     * hubiera escrito el repago no habria habido forma de cerrarlo.
     * ---------------------------------------------------------------- */

    function test_Bug9_StablecoinMintAndBurnAreVaultOnly() public {
        vm.expectRevert(GovStablecoin.OnlyVault.selector);
        vm.prank(bob);
        stable.mint(bob, 1e18);

        vm.prank(alice);
        vault.depositAndMint(100e18, 30e18);

        vm.expectRevert(GovStablecoin.OnlyVault.selector);
        vm.prank(bob);
        stable.burn(alice, 30e18);
    }

    /* ---------------------------------------------------------------- *
     * BUG 10 - El precio del vault de zkSync estaba hardcodeado en el
     * codigo. Ahora el precio viene siempre del feed inyectado.
     * ---------------------------------------------------------------- */

    function test_Bug10_PriceComesFromTheFeed() public {
        assertEq(vault.getPrice(), 0.6e18);

        feed.setAnswer(1.2e8);
        assertEq(vault.getPrice(), 1.2e18, "el precio sigue al feed, no esta fijado");

        vm.prank(alice);
        vault.deposit(100e18);
        assertEq(vault.maxMintable(alice), 60e18, "y mueve el poder de emision");
    }
}
