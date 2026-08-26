// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";
import {DelegationAccount} from "../src/DelegationAccount.sol";
import {GovStablecoin} from "../src/GovStablecoin.sol";

/// @title V1Regression
/// @notice One test per defect found in the hackathon version.
/// @dev Each `test_` documents what v1 did and proves it no longer happens.
///      They act as a safety net and, above all, as a written record of the
///      review.
contract V1RegressionTest is BaseTest {
    /* ---------------------------------------------------------------- *
     * BUG 1 - Collateral stayed in the vault instead of the delegation
     * account, so delegation delegated a zero balance and the collateral's
     * voting power simply vanished.
     * ---------------------------------------------------------------- */

    function test_Bug1_CollateralLandsInDelegationAccountNotVault() public {
        vm.prank(alice);
        vault.deposit(100e18);

        address account = vault.accountOf(alice);

        assertEq(token.balanceOf(account), 100e18, "collateral must live in the user's account");
        assertEq(token.balanceOf(address(vault)), 0, "the vault must not custody collateral");
    }

    function test_Bug1_DepositingDoesNotCostVotingPower() public {
        // Alice self-delegates, as any holder who votes would.
        vm.prank(alice);
        token.delegate(alice);

        uint256 votesBefore = token.getVotes(alice);
        assertEq(votesBefore, INITIAL_BALANCE);

        vm.prank(alice);
        vault.depositAndMint(400e18, 100e18);

        // This is the entire thesis of the protocol: she deposits, takes on debt,
        // and her voting power has not moved by a single wei. In v1 it dropped
        // to 600e18.
        assertEq(token.getVotes(alice), votesBefore, "depositing must not cost voting power");
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 400e18, "and the tokens did leave her wallet");
    }

    function test_Bug1_DelegationAccountSelfDelegatesToOwner() public {
        vm.prank(alice);
        vault.deposit(100e18);

        assertEq(vault.delegateOf(alice), alice, "the account must delegate to its owner up front");
    }

    /* ---------------------------------------------------------------- *
     * BUG 2 - The stablecoin was minted to the delegation account, which
     * had no function to move it. It was stuck there forever and the user
     * never saw it.
     * ---------------------------------------------------------------- */

    function test_Bug2_StablecoinIsMintedToTheUser() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 20e18);

        address account = vault.accountOf(alice);

        assertEq(stable.balanceOf(alice), 20e18, "the stablecoin belongs to the user");
        assertEq(stable.balanceOf(account), 0, "the delegation account must not hold it");
    }

    function test_Bug2_UserCanActuallySpendTheStablecoin() public {
        vm.prank(alice);
        vault.depositAndMint(100e18, 20e18);

        // What v1 made impossible: using it in DeFi.
        vm.prank(alice);
        stable.transfer(bob, 20e18);

        assertEq(stable.balanceOf(bob), 20e18);
    }

    /* ---------------------------------------------------------------- *
     * BUG 3 - A 1e18 scaling error. v1 multiplied price (18 dec) by amount
     * (18 dec) and minted the 36-decimal result as if it had 18, minting
     * 1e18 times too much.
     * ---------------------------------------------------------------- */

    function test_Bug3_MintAmountHasCorrectScale() public {
        // 100 tokens at 0.60 USD = 60 USD of collateral, 50% LTV = 30 gUSD.
        vm.prank(alice);
        vault.deposit(100e18);

        assertEq(vault.collateralValue(alice), 60e18, "collateral USD value with 18 decimals");
        assertEq(vault.maxMintable(alice), 30e18, "correct mintable ceiling");

        vm.prank(alice);
        vault.mint(30e18);

        assertEq(stable.balanceOf(alice), 30e18);
        // v1 would have minted 30e36. Checked explicitly.
        assertLt(stable.balanceOf(alice), 30e36, "v1 minted 1e18 times too much");
    }

    function test_Bug3_CannotMintMoreThanLtvAllows() public {
        vm.prank(alice);
        vault.deposit(100e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralVotingVault.ExceedsMaxLtv.selector, 30e18 + 1, 30e18));
        vm.prank(alice);
        vault.mint(30e18 + 1);
    }

    /* ---------------------------------------------------------------- *
     * BUG 4 - `createUserDelegationAccount` was `public` and accepted any
     * address, so anyone could overwrite another user's delegation account.
     * ---------------------------------------------------------------- */

    function test_Bug4_AccountCreationIsNotHijackable() public {
        vm.prank(alice);
        vault.deposit(100e18);
        address aliceAccount = vault.accountOf(alice);

        // Bob has no way to create or replace alice's account: the only entry
        // point is `openAccount`, which always operates on msg.sender.
        vm.prank(bob);
        address bobAccount = vault.openAccount();

        assertTrue(bobAccount != aliceAccount, "each user gets their own account");
        assertEq(vault.accountOf(alice), aliceAccount, "alice's account did not change");
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
     * BUG 5 - `userLockedTokens[msg.sender] = amount` overwrote instead of
     * accumulating, so the second deposit erased the first.
     * ---------------------------------------------------------------- */

    function test_Bug5_MultipleDepositsAccumulate() public {
        vm.startPrank(alice);
        vault.deposit(100e18);
        vault.deposit(50e18);
        vault.deposit(25e18);
        vm.stopPrank();

        assertEq(vault.collateralOf(alice), 175e18, "deposits add up");
        assertEq(token.balanceOf(vault.accountOf(alice)), 175e18);
    }

    /* ---------------------------------------------------------------- *
     * BUG 6 - There was no way out. `returnGovernanceTokens` was written
     * but never called by anyone: collateral went in and never came back.
     * ---------------------------------------------------------------- */

    function test_Bug6_FullRoundTripReturnsAllCollateral() public {
        uint256 balanceBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        vault.depositAndMint(100e18, 30e18);
        stable.approve(address(vault), type(uint256).max);
        vault.repayAndWithdraw(30e18, 100e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), balanceBefore, "gets all her collateral back");
        assertEq(vault.debtOf(alice), 0, "no debt");
        assertEq(vault.collateralOf(alice), 0, "no collateral locked");
        assertEq(stable.totalSupply(), 0, "the minted stablecoin was burned");
    }

    /* ---------------------------------------------------------------- *
     * BUG 7 - `depositAndMintStablecoin` declared `returns(uint)` and never
     * returned: it silently handed back 0 every time.
     * ---------------------------------------------------------------- */

    function test_Bug7_ReturnValuesAreReal() public {
        vm.startPrank(alice);
        vault.depositAndMint(100e18, 30e18);
        stable.approve(address(vault), type(uint256).max);

        uint256 repaid = vault.repay(10e18);
        vm.stopPrank();

        assertEq(repaid, 10e18, "repay returns what was actually repaid");
    }

    /* ---------------------------------------------------------------- *
     * BUG 8 - Zero events in the whole system: nothing was indexable.
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
     * BUG 9 - v1's stablecoin had no `burn`, so even if repayment had been
     * written there would have been no way to settle it.
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
     * BUG 10 - The zkSync vault had its price hardcoded in the source.
     * The price now always comes from the injected feed.
     * ---------------------------------------------------------------- */

    function test_Bug10_PriceComesFromTheFeed() public {
        assertEq(vault.getPrice(), 0.6e18);

        feed.setAnswer(1.2e8);
        assertEq(vault.getPrice(), 1.2e18, "the price tracks the feed, it is not pinned");

        vm.prank(alice);
        vault.deposit(100e18);
        assertEq(vault.maxMintable(alice), 60e18, "and it moves the minting capacity");
    }
}
