//SPDX-License-Identifier: MIT

import "../stablecoins/arbStablecoin.sol";

pragma solidity 0.8.24;

interface arbGovernanceToken
{
    function transferFrom( address from, address to, uint256 amount ) external returns (bool);
    function delegate(address delegatee) external;
    function allowance(address owner, address spender) external returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract arbDelegationAccount
{
    address ARB_MOCKUP_TOKEN_ADDRESS = 0x539892873B37786C65E3af92DB751c6456b3ecaE;

    address public collateralVotingVault;
    address public userAddress;





    constructor(address paramUserAddress)
    {
        collateralVotingVault = msg.sender;
        userAddress = paramUserAddress;
    }

    function delegate(address paramDelegateeAddress) public
    {
        require(msg.sender == userAddress || msg.sender == collateralVotingVault, "Not allowed caller.");
        arbGovernanceToken(ARB_MOCKUP_TOKEN_ADDRESS).delegate(paramDelegateeAddress);
    }

    function returnGovernanceTokens(uint paramMappedQuantity) public
    {
        require(msg.sender == collateralVotingVault, "Not collateralVotingVault.");
        arbGovernanceToken(ARB_MOCKUP_TOKEN_ADDRESS).transfer(userAddress, paramMappedQuantity);
    }

    function getAddress() public view returns(address)
    {
        return address(this);
    }
}