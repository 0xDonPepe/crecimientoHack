//SPDX-License-Identifier: MIT

import "../stablecoins/zkStablecoin.sol";
import "./zkDelegationAccount.sol";

pragma solidity 0.8.24;

interface zkGovernanceTokenInterface
{
    function transferFrom( address from, address to, uint256 amount ) external returns (bool);
    function delegate(address delegatee) external;
    function allowance(address owner, address spender) external returns (uint256);
}

//THIS INTERFACE IS SUPPOSED TO BE USED FOR CHAINLINK PRICE FEED, YET FOR ZKSYNC SEPOLIA TESTNET IS NOT AVAILABLE THE ZK TOKEN PRICE.//
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

contract lockedZkCollateralVotingVault
{
    address ZK_MOCKUP_TOKEN_ADDRESS = 0x87545014d8F8452Ed9D8f1013bF0B7C193f191C1;

    mapping(address => uint256) public userLockedTokens;
    mapping(address => bool) public delegationAccountExists;
    mapping(address => address) public userDelegationAccount;
    mapping(address => uint) public userZkCollateralUsed;
    mapping(address => uint) public userMintedZkStablecoin;


    //THIS PRICE FEED INSTANCE IS SUPPOSED TO BE USED TO GET ZK TOKEN PRICE, YET FOR ZKSYNC SEPOLIA TESTNET IS NOT AVAILABLE THE ZK TOKEN PRICE.///
    //THE ADDRESS USED HERE IS FOR ZKSYNC MAINNET SINCE THERES NO PRICE FEED FOR ZK TOKEN ON SEPOLIA TESTNET.///
    AggregatorV3Interface internal priceDataFeed = AggregatorV3Interface(0xD1ce60dc8AE060DDD17cA8716C96f193bC88DD13);
    zkStablecoin internal zkSyncStablecoin;
    





    constructor()
    {
        zkSyncStablecoin = new zkStablecoin();
    }



    //THIS FUNCTION IS SUPPOSED TO BE USED TO GET ZK TOKEN PRICE, YET FOR ZKSYNC SEPOLIA TESTNET IS NOT AVAILABLE THE ZK TOKEN PRICE.///
    function getZkPrice() public view returns(int)
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
        zkDelegationAccount newAccount = new zkDelegationAccount(paramUserAddress);
        address newAccountAddress = newAccount.getAddress(); 


        delegationAccountExists[paramUserAddress] = true;
        userDelegationAccount[paramUserAddress] = newAccountAddress;

        return newAccountAddress;
    }

    function depositAndMintStablecoin(uint256 paramAmountToUse) public returns(uint)
    {
        require(zkGovernanceTokenInterface(ZK_MOCKUP_TOKEN_ADDRESS).allowance(msg.sender, address(this)) >= paramAmountToUse, "Vault doesnt have enough allowance of arbGovernanceToken, please increase it.");


        zkGovernanceTokenInterface(ZK_MOCKUP_TOKEN_ADDRESS).transferFrom(msg.sender, address(this), paramAmountToUse);
        userLockedTokens[msg.sender] = paramAmountToUse;

        //HERE, getZkPrice SHOULD GET THE ZK TOKEN PRICE FROM THE CHAINLINK PRICE FEED, BUT SINCE IT IS NOT AVAILABLE ON THE SEPOLIA TESTNET HERE WE ARE GOING TO HARDCODE IT.///

        // uint zkPrice = uint(getZkPrice()) * (10 ** 10);
        uint zkPrice = uint(12773200) * (10 ** 10);
        uint collateralValue = zkPrice * paramAmountToUse;
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

        zkSyncStablecoin.mint(userAccount, stablecoinToMint);

        userZkCollateralUsed[msg.sender] += paramAmountToUse;
        userMintedZkStablecoin[msg.sender] += stablecoinToMint;
    }

    function delegateLockedGovernanceTokens(address paramDelegateeAddress) public
    {
        require(delegationAccountExists[msg.sender], "User doesnt own delegationAccount.");

        zkDelegationAccount(userDelegationAccount[msg.sender]).delegate(paramDelegateeAddress);
    }

    function getZkStablecoinAddress() public view returns(address)
    {
        return zkSyncStablecoin.getAddress();
    }
}