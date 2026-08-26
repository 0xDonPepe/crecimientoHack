// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title MockPriceFeed
/// @notice Controllable Chainlink feed, for testing price crashes, negative
///         prices and stuck rounds.
contract MockPriceFeed is IAggregatorV3 {
    uint8 private immutable _decimals;
    string private _description;

    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;
    uint80 private _answeredInRound;

    constructor(uint8 decimals_, int256 initialAnswer, string memory description_) {
        _decimals = decimals_;
        _description = description_;
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
        _roundId = 1;
        _answeredInRound = 1;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }

    /// @notice Publishes a new price in a new round.
    function setAnswer(int256 answer) external {
        _answer = answer;
        _updatedAt = block.timestamp;
        _roundId += 1;
        _answeredInRound = _roundId;
    }

    /// @notice Forces the timestamp, to simulate a stale feed.
    function setUpdatedAt(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    /// @notice Simulates an open round carrying over the previous answer.
    function setStuckRound() external {
        _roundId += 1;
    }
}
