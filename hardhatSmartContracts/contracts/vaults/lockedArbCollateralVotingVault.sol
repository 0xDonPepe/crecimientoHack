//SPDX-License-Identifier: MIT

import "../stablecoins/arbStablecoin.sol";
import "./arbDelegationAccount.sol";

pragma solidity 0.8.24;

interface arbGovernanceTokenInterface
{
    function transferFrom( address from, address to, uint256 amount ) external returns (bool);
    function delegate(address delegatee) external;
    function allowance(address owner, address spender) external returns (uint256);
}

interface AggregatorV3Interface 
{
  function decimals() external view returns (uint8);

  function description() external view returns (string memory);

  function version() external view returns (uint256);

  function getRoundData(
    uint80 _roundId
  ) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract lockedArbCollateralVotingVault
{
    address ARB_MOCKUP_TOKEN_ADDRESS = 0x539892873B37786C65E3af92DB751c6456b3ecaE;

    mapping(address => uint256) public userLockedTokens;
    mapping(address => bool) public delegationAccountExists;
    mapping(address => address) public userDelegationAccount;
    mapping(address => uint) public userArbCollateralUsed;
    mapping(address => uint) public userMintedArbStablecoin;


    AggregatorV3Interface internal priceDataFeed = AggregatorV3Interface(0xD1092a65338d049DB68D7Be6bD89d17a0929945e);
    arbStablecoin internal arbitrumStablecoin;
    





    constructor()
    {
        arbitrumStablecoin = new arbStablecoin();
    }



    //returns arb price with 8 decimals///
    function getArbPrice() public view returns(int)
    {
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = priceDataFeed.latestRoundData();

        return answer;
    }

    function createUserDelegationAccount(address paramUserAddress) public returns(address)
    {
        arbDelegationAccount newAccount = new arbDelegationAccount(paramUserAddress);
        address newAccountAddress = newAccount.getAddress(); 


        delegationAccountExists[paramUserAddress] = true;
        userDelegationAccount[paramUserAddress] = newAccountAddress;

        return newAccountAddress;
    }

    function depositAndMintStablecoin(uint256 paramAmountToUse) public returns(uint)
    {
        require(arbGovernanceTokenInterface(ARB_MOCKUP_TOKEN_ADDRESS).allowance(msg.sender, address(this)) >= paramAmountToUse, "Vault doesnt have enough allowance of arbGovernanceToken, please increase it.");


        arbGovernanceTokenInterface(ARB_MOCKUP_TOKEN_ADDRESS).transferFrom(msg.sender, address(this), paramAmountToUse);
        userLockedTokens[msg.sender] = paramAmountToUse;

        //Converts the price from 8 decimals to 18 decimals///
        uint arbPrice = uint(getArbPrice()) * (10 ** 10);
        uint collateralValue = arbPrice * paramAmountToUse;
        uint stablecoinToMint = collateralValue / 2;

        address userAccount;

        if(!delegationAccountExists[msg.sender])
        {
            userAccount = createUserDelegationAccount(msg.sender);
        }
        else
        {
            userAccount = userDelegationAccount[msg.sender];
        }

        arbitrumStablecoin.mint(userAccount, stablecoinToMint);

        userArbCollateralUsed[msg.sender] += paramAmountToUse;
        userMintedArbStablecoin[msg.sender] += stablecoinToMint;
    }

    function delegateLockedGovernanceTokens(address paramDelegateeAddress) public
    {
        require(delegationAccountExists[msg.sender], "User doesnt own delegationAccount.");

        arbDelegationAccount(userDelegationAccount[msg.sender]).delegate(paramDelegateeAddress);
    }

    function getArbStablecoinAddress() public view returns(address)
    {
        return arbitrumStablecoin.getAddress();
    }
}