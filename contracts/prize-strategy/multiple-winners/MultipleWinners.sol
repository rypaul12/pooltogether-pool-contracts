// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import "../PeriodicPrizeStrategy.sol";

contract MultipleWinners is PeriodicPrizeStrategy {
    uint256 internal __numberOfWinners;

    bool public splitExternalErc20Awards;

    struct MultipleWinnersPrizeSplit {
        address target;
        uint8 percentage;
    }

    MultipleWinnersPrizeSplit[] internal _prizeSplits;

    event SplitExternalErc20AwardsSet(bool splitExternalErc20Awards);

    event NumberOfWinnersSet(uint256 numberOfWinners);

    event NoWinners();

    function initializeMultipleWinners(
        uint256 _prizePeriodStart,
        uint256 _prizePeriodSeconds,
        PrizePool _prizePool,
        TicketInterface _ticket,
        IERC20Upgradeable _sponsorship,
        RNGInterface _rng,
        uint256 _numberOfWinners
    ) public initializer {
        IERC20Upgradeable[] memory _externalErc20Awards;

        PeriodicPrizeStrategy.initialize(
            _prizePeriodStart,
            _prizePeriodSeconds,
            _prizePool,
            _ticket,
            _sponsorship,
            _rng,
            _externalErc20Awards
        );

        _setNumberOfWinners(_numberOfWinners);
    }

    function setSplitExternalErc20Awards(bool _splitExternalErc20Awards)
        external
        onlyOwner
        requireAwardNotInProgress
    {
        splitExternalErc20Awards = _splitExternalErc20Awards;

        emit SplitExternalErc20AwardsSet(splitExternalErc20Awards);
    }

    function setNumberOfWinners(uint256 count)
        external
        onlyOwner
        requireAwardNotInProgress
    {
        _setNumberOfWinners(count);
    }

    function setPrizeSplit(
        MultipleWinnersPrizeSplit[2] memory prizeStrategySplit
    ) external onlyOwner {
        for (uint256 index = 0; index < prizeStrategySplit.length; index++) {
            MultipleWinnersPrizeSplit memory split = prizeStrategySplit[index];

            // If MultipleWinnersPrizeSplit is non-zero address store the split in array.
            if (split.target != address(0)) {
                // Split percentage must be below 100 (e.x. 20 is equal to 20% percent)
                require(
                    split.percentage > 0 && split.percentage < 100,
                    "MultipleWinners:invalid-prizesplit-percentage-amount"
                );
                _prizeSplits.push(split);
            }
        }
    }

    function _setNumberOfWinners(uint256 count) internal {
        require(count > 0, "MultipleWinners/winners-gte-one");

        __numberOfWinners = count;
        emit NumberOfWinnersSet(count);
    }

    function numberOfWinners() external view returns (uint256) {
        return __numberOfWinners;
    }

    /**
     * @dev Calculate the PrizeSplit percentage
     * @param amount The prize amount
     */
    function _getPrizeSplitPercentage(uint256 amount, uint8 percentage)
        internal
        pure
        returns (uint256)
    {
        return (amount * percentage) / 100; // PrizeSplit percentage amount
    }

    /**
     * @dev Award prize split target with award amount
     * @param target Receiver of the prize split fee.
     * @param splitAmount Split amount to be awarded to target.
     */
    function _awardPrizeSplitAmount(address target, uint256 splitAmount)
        internal
    {
        _awardTickets(target, splitAmount);
    }

    function _distribute(uint256 randomNumber) internal override {
        uint256 prize = prizePool.captureAwardBalance();

        // If PrizeSplits has been set, iterate of the prizeSplits and transfer award amount.
        if (_prizeSplits.length > 0) {
            // Store temporary total prize amount for multiple calculations using initial prize amount.
            uint256 _prizeTemp = prize;

            // Iterate over prize splits array to calculate
            for (uint256 index = 0; index < _prizeSplits.length; index++) {
                MultipleWinnersPrizeSplit memory split = _prizeSplits[index];

                // Calculate the split amount using the prize amount and split percentage.
                uint256 _splitAmount =
                    _getPrizeSplitPercentage(_prizeTemp, split.percentage);

                // Award the PrizeSplit amount to split target
                _awardPrizeSplitAmount(split.target, _splitAmount);

                // Update the remaining prize amount after distributing the prize split percentage.
                prize -= _splitAmount;
            }
        }

        // main winner is simply the first that is drawn
        address mainWinner = ticket.draw(randomNumber);

        // If drawing yields no winner, then there is no one to pick
        if (mainWinner == address(0)) {
            emit NoWinners();
            return;
        }

        // main winner gets all external ERC721 tokens
        _awardExternalErc721s(mainWinner);

        address[] memory winners = new address[](__numberOfWinners);
        winners[0] = mainWinner;

        uint256 nextRandom = randomNumber;
        for (
            uint256 winnerCount = 1;
            winnerCount < __numberOfWinners;
            winnerCount++
        ) {
            // add some arbitrary numbers to the previous random number to ensure no matches with the UniformRandomNumber lib
            bytes32 nextRandomHash =
                keccak256(
                    abi.encodePacked(nextRandom + 499 + winnerCount * 521)
                );
            nextRandom = uint256(nextRandomHash);
            winners[winnerCount] = ticket.draw(nextRandom);
        }

        // yield prize is split up among all winners
        uint256 prizeShare = prize.div(winners.length);
        if (prizeShare > 0) {
            for (uint256 i = 0; i < winners.length; i++) {
                _awardTickets(winners[i], prizeShare);
            }
        }

        if (splitExternalErc20Awards) {
            address currentToken = externalErc20s.start();
            while (
                currentToken != address(0) &&
                currentToken != externalErc20s.end()
            ) {
                uint256 balance =
                    IERC20Upgradeable(currentToken).balanceOf(
                        address(prizePool)
                    );
                uint256 split = balance.div(__numberOfWinners);
                if (split > 0) {
                    for (uint256 i = 0; i < winners.length; i++) {
                        prizePool.awardExternalERC20(
                            winners[i],
                            currentToken,
                            split
                        );
                    }
                }
                currentToken = externalErc20s.next(currentToken);
            }
        } else {
            _awardExternalErc20s(mainWinner);
        }
    }
}
