pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract arbStablecoin is ERC20, ERC20Permit 
{
    address public collateralVotingVault;





    constructor()
        ERC20("arbitrumStablecoin", "arbSC")
        ERC20Permit("arbitrumStablecoin")
    {
        collateralVotingVault = msg.sender;
    }

    function mint(address to, uint256 amount) public
    {
        require(msg.sender == collateralVotingVault, "Msg.sender not collateralVotingVault.");

        _mint(to, amount);
    }

    function getAddress() public view returns(address)
    {
        return address(this);
    }
}