// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";
import {DelegationAccount} from "../src/DelegationAccount.sol";
import {GovStablecoin} from "../src/GovStablecoin.sol";
import {MockGovernanceToken} from "../src/mocks/MockGovernanceToken.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

/// @notice Montaje comun a toda la suite.
/// @dev Precio inicial de 0.60 USD con 8 decimales, como el feed real de ARB.
abstract contract BaseTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant INITIAL_PRICE = 0.6e8;

    uint256 internal constant MAX_LTV = 5_000; // 50%
    uint256 internal constant LIQ_THRESHOLD = 7_500; // 75%
    uint256 internal constant LIQ_BONUS = 1_000; // 10%
    uint256 internal constant CLOSE_FACTOR = 5_000; // 50%
    uint256 internal constant MAX_PRICE_AGE = 1 hours;

    uint256 internal constant INITIAL_BALANCE = 1_000e18;

    MockGovernanceToken internal token;
    MockPriceFeed internal feed;
    CollateralVotingVault internal vault;
    GovStablecoin internal stable;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public virtual {
        token = new MockGovernanceToken("Mock Governance", "MGOV");
        feed = new MockPriceFeed(FEED_DECIMALS, INITIAL_PRICE, "MGOV / USD");

        vault = new CollateralVotingVault(
            address(token),
            address(feed),
            "Governance Stablecoin",
            "gUSD",
            MAX_LTV,
            LIQ_THRESHOLD,
            LIQ_BONUS,
            CLOSE_FACTOR,
            MAX_PRICE_AGE,
            owner
        );
        stable = vault.stablecoin();

        address[4] memory users = [alice, bob, carol, liquidator];
        for (uint256 i; i < users.length; ++i) {
            token.mint(users[i], INITIAL_BALANCE);
            vm.prank(users[i]);
            token.approve(address(vault), type(uint256).max);
        }

        // El tiempo arranca en 1 en Foundry; se avanza para poder simular
        // precios rancios sin que `block.timestamp - updatedAt` haga underflow.
        vm.warp(1_700_000_000);
        feed.setAnswer(INITIAL_PRICE);
    }

    /* --------------------------- utilidades --------------------------- */

    /// @dev Da `amount` de stablecoin a `to` abriendo una posicion sana de carol.
    ///      Sirve para financiar a un liquidador sin romper la contabilidad.
    function _fundStablecoin(address to, uint256 amount) internal {
        uint256 needed = (amount * WAD * BPS) / (vault.getPrice() * MAX_LTV) + 1e18;
        token.mint(carol, needed);
        vm.startPrank(carol);
        token.approve(address(vault), type(uint256).max);
        vault.depositAndMint(needed, amount);
        stable.transfer(to, amount);
        vm.stopPrank();
    }

    /// @dev Valor en USD (18 dec) de `amount` tokens al precio actual del feed.
    function _usd(uint256 amount) internal view returns (uint256) {
        return (amount * vault.getPrice()) / WAD;
    }
}
