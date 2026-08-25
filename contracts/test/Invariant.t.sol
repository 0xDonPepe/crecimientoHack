// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";
import {DelegationAccount} from "../src/DelegationAccount.sol";
import {GovStablecoin} from "../src/GovStablecoin.sol";
import {MockGovernanceToken} from "../src/mocks/MockGovernanceToken.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

/// @notice Conductor que golpea el vault con secuencias aleatorias de acciones.
contract Handler is CommonBase, StdCheats, StdUtils {
    CollateralVotingVault public immutable vault;
    MockGovernanceToken public immutable token;
    MockPriceFeed public immutable feed;
    GovStablecoin public immutable stable;

    address[] public actors;
    address internal currentActor;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostSeized;

    modifier useActor(uint256 seed) {
        currentActor = actors[bound(seed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(CollateralVotingVault vault_, MockGovernanceToken token_, MockPriceFeed feed_) {
        vault = vault_;
        token = token_;
        feed = feed_;
        stable = vault_.stablecoin();

        for (uint256 i; i < 5; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(actor);
            token.mint(actor, 1_000e18);
            vm.prank(actor);
            token.approve(address(vault), type(uint256).max);
            vm.prank(actor);
            stable.approve(address(vault), type(uint256).max);
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function deposit(uint256 seed, uint256 amount) external useActor(seed) {
        amount = bound(amount, 0, token.balanceOf(currentActor));
        if (amount == 0) return;
        vault.deposit(amount);
        ghostDeposited += amount;
    }

    function mint(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 limit = vault.maxMintable(currentActor);
        amount = bound(amount, 0, limit);
        if (amount == 0) return;
        vault.mint(amount);
    }

    function repay(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 debt = vault.debtOf(currentActor);
        uint256 balance = stable.balanceOf(currentActor);
        uint256 cap = debt < balance ? debt : balance;
        amount = bound(amount, 0, cap);
        if (amount == 0) return;
        vault.repay(amount);
    }

    function withdraw(uint256 seed, uint256 amount) external useActor(seed) {
        amount = bound(amount, 0, vault.collateralOf(currentActor));
        if (amount == 0) return;
        // Solo se intenta lo que deja la posicion sana; el resto revertiria.
        try vault.withdraw(amount) {
            ghostWithdrawn += amount;
        } catch {}
    }

    function delegate(uint256 seed, uint256 delegateeSeed) external useActor(seed) {
        if (vault.accountOf(currentActor) == address(0)) return;
        vault.delegate(actors[bound(delegateeSeed, 0, actors.length - 1)]);
    }

    function liquidate(uint256 seed, uint256 victimSeed, uint256 amount) external useActor(seed) {
        address victim = actors[bound(victimSeed, 0, actors.length - 1)];
        if (victim == currentActor) return;
        if (!vault.isLiquidatable(victim)) return;

        amount = bound(amount, 1, stable.balanceOf(currentActor));
        if (amount == 0) return;

        try vault.liquidate(victim, amount) returns (uint256 seized) {
            ghostSeized += seized;
        } catch {}
    }

    /// @dev Mueve el precio dentro de un rango amplio pero siempre positivo.
    function movePrice(uint256 newPrice) external {
        feed.setAnswer(int256(bound(newPrice, 0.01e8, 10e8)));
    }
}

/// @notice Invariantes contables del protocolo.
contract InvariantTest is Test {
    MockGovernanceToken internal token;
    MockPriceFeed internal feed;
    CollateralVotingVault internal vault;
    GovStablecoin internal stable;
    Handler internal handler;

    function setUp() public {
        token = new MockGovernanceToken("Mock Governance", "MGOV");
        feed = new MockPriceFeed(8, 0.6e8, "MGOV / USD");
        vault = new CollateralVotingVault(
            address(token),
            address(feed),
            "Governance Stablecoin",
            "gUSD",
            5_000,
            7_500,
            1_000,
            5_000,
            1 hours,
            address(this)
        );
        stable = vault.stablecoin();

        handler = new Handler(vault, token, feed);
        targetContract(address(handler));
    }

    /// @notice Cada gUSD en circulacion corresponde a deuda registrada.
    function invariant_SupplyEqualsTotalDebt() public view {
        assertEq(stable.totalSupply(), vault.totalDebt());
    }

    /// @notice El acumulado por usuario cuadra con el total.
    function invariant_CollateralAccountingMatches() public view {
        uint256 sum;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            sum += vault.collateralOf(handler.actors(i));
        }
        assertEq(sum, vault.totalCollateral());
    }

    /// @notice La deuda por usuario cuadra con el total.
    function invariant_DebtAccountingMatches() public view {
        uint256 sum;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            sum += vault.debtOf(handler.actors(i));
        }
        assertEq(sum, vault.totalDebt());
    }

    /// @notice El colateral registrado esta realmente en la cuenta del usuario.
    ///         Este es el invariante que la v1 violaba de forma sistematica.
    function invariant_EachAccountHoldsItsOwnCollateral() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            address account = vault.accountOf(actor);
            if (account == address(0)) continue;
            assertEq(token.balanceOf(account), vault.collateralOf(actor));
        }
    }

    /// @notice El vault nunca custodia colateral ni stablecoin.
    function invariant_VaultHoldsNothing() public view {
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(stable.balanceOf(address(vault)), 0);
    }

    /// @notice Toda cuenta creada tiene delegatee: el voto nunca se pierde.
    function invariant_NoVotingPowerIsStranded() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            address account = vault.accountOf(handler.actors(i));
            if (account == address(0)) continue;
            if (token.balanceOf(account) == 0) continue;
            assertTrue(DelegationAccount(account).currentDelegate() != address(0), "colateral sin delegar");
        }
    }
}
