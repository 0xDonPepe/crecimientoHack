// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {CollateralVotingVault} from "../src/CollateralVotingVault.sol";
import {MockGovernanceToken} from "../src/mocks/MockGovernanceToken.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

/// @notice Despliega un vault contra un token y un feed que ya existen.
/// @dev Todo se lee del entorno, nada esta cableado en el codigo. La v1 tenia
///      las direcciones escritas dentro de los contratos.
///
///      forge script script/Deploy.s.sol:Deploy --rpc-url arbitrum --broadcast --verify
contract Deploy is Script {
    /// @dev Agrupada en un struct para no agotar la pila de la EVM.
    struct Config {
        address collateral;
        address feed;
        address owner;
        string name;
        string symbol;
        uint256 maxLtv;
        uint256 liqThreshold;
        uint256 liqBonus;
        uint256 closeFactor;
        uint256 maxPriceAge;
    }

    function readConfig() public view returns (Config memory c) {
        c.collateral = vm.envAddress("COLLATERAL_TOKEN");
        c.feed = vm.envAddress("PRICE_FEED");
        c.owner = vm.envAddress("VAULT_OWNER");
        c.name = vm.envOr("STABLECOIN_NAME", string("Governance Stablecoin"));
        c.symbol = vm.envOr("STABLECOIN_SYMBOL", string("gUSD"));
        c.maxLtv = vm.envOr("MAX_LTV_BPS", uint256(5_000));
        c.liqThreshold = vm.envOr("LIQUIDATION_THRESHOLD_BPS", uint256(7_500));
        c.liqBonus = vm.envOr("LIQUIDATION_BONUS_BPS", uint256(1_000));
        c.closeFactor = vm.envOr("CLOSE_FACTOR_BPS", uint256(5_000));
        c.maxPriceAge = vm.envOr("MAX_PRICE_AGE", uint256(1 hours));
    }

    function run() external returns (CollateralVotingVault vault) {
        Config memory c = readConfig();

        vm.startBroadcast();
        vault = new CollateralVotingVault(
            c.collateral,
            c.feed,
            c.name,
            c.symbol,
            c.maxLtv,
            c.liqThreshold,
            c.liqBonus,
            c.closeFactor,
            c.maxPriceAge,
            c.owner
        );
        vm.stopBroadcast();

        console2.log("CollateralVotingVault  ", address(vault));
        console2.log("GovStablecoin          ", address(vault.stablecoin()));
        console2.log("DelegationAccount impl ", vault.accountImplementation());
        console2.log("collateralToken        ", c.collateral);
        console2.log("priceFeed              ", c.feed);
        console2.log("owner                  ", c.owner);
    }
}

/// @notice Despliegue completo de testnet: token mock, feed mock y vault.
/// @dev Para redes donde no hay un feed de Chainlink del token de gobernanza.
///      En la v1 esto se resolvia cableando el precio dentro del contrato.
///
///      forge script script/Deploy.s.sol:DeployTestnet --rpc-url arbitrum_sepolia --broadcast
contract DeployTestnet is Script {
    function run() external returns (MockGovernanceToken token, MockPriceFeed feed, CollateralVotingVault vault) {
        address owner = vm.envOr("VAULT_OWNER", msg.sender);
        int256 initialPrice = int256(vm.envOr("INITIAL_PRICE", uint256(0.6e8)));

        vm.startBroadcast();

        token = new MockGovernanceToken("Mock Governance", "MGOV");
        feed = new MockPriceFeed(8, initialPrice, "MGOV / USD");
        vault = new CollateralVotingVault(
            address(token), address(feed), "Governance Stablecoin", "gUSD", 5_000, 7_500, 1_000, 5_000, 1 hours, owner
        );

        // Reparto inicial para poder probar la dApp de inmediato.
        token.mint(msg.sender, 1_000_000e18);

        vm.stopBroadcast();

        console2.log("MockGovernanceToken    ", address(token));
        console2.log("MockPriceFeed          ", address(feed));
        console2.log("CollateralVotingVault  ", address(vault));
        console2.log("GovStablecoin          ", address(vault.stablecoin()));
    }
}
