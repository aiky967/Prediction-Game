// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
pragma abicoder v2;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title ImprovedPricePredictionGame
 */
contract ImprovedPricePredictionGame is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    AggregatorV3Interface public oracle;

    bool public genesisLockOnce = false;
    bool public genesisStartOnce = false;

    address public adminAddress;
    address public operatorAddress;

    uint256 public bufferSeconds;
    uint256 public intervalSeconds;

    uint256 public minBetAmount;
    uint256 public treasuryFee;
    uint256 public treasuryAmount;

    uint256 public currentEpoch;
    uint256 public oracleLatestRoundId;
    uint256 public oracleUpdateAllowance;

    uint256 public constant MAX_TREASURY_FEE = 1000;

    mapping(uint256 => mapping(address => BetInfo)) public ledger;
    mapping(uint256 => Round) public rounds;
    mapping(address => uint256[]) public userRounds;

    enum Position {
        Bull,
        Bear
    }

    struct Round {
        uint256 epoch;
        uint256 startTimestamp;
        uint256 lockTimestamp;
        uint256 closeTimestamp;
        int256 lockPrice;
        int256 closePrice;
        uint256 lockOracleId;
        uint256 closeOracleId;
        uint256 totalAmount;
        uint256 bullAmount;
        uint256 bearAmount;
        uint256 rewardBaseCalAmount;
        uint256 rewardAmount;
        bool oracleCalled;
    }

    struct BetInfo {
        Position position;
        uint256 amount;
        bool claimed;
    }

    event BetBear(address indexed sender, uint256 indexed epoch, uint256 amount);
    event BetBull(address indexed sender, uint256 indexed epoch, uint256 amount);
    event Claim(address indexed sender, uint256 indexed epoch, uint256 amount);
    event EndRound(uint256 indexed epoch, uint256 indexed roundId, int256 price);
    event LockRound(uint256 indexed epoch, uint256 indexed roundId, int256 price);

    event NewAdminAddress(address admin);
    event NewBufferAndIntervalSeconds(uint256 bufferSeconds, uint256 intervalSeconds);
    event NewMinBetAmount(uint256 indexed epoch, uint256 minBetAmount);
    event NewTreasuryFee(uint256 indexed epoch, uint256 treasuryFee);
    event NewOperatorAddress(address operator);
    event NewOracle(address oracle);
    event NewOracleUpdateAllowance(uint256 oracleUpdateAllowance);

    event Pause(uint256 indexed epoch);
    event RewardsCalculated(
        uint256 indexed epoch,
        uint256 rewardBaseCalAmount,
        uint256 rewardAmount,
        uint256 treasuryAmount
    );

    event StartRound(uint256 indexed epoch);
    event TokenRecovery(address indexed token, uint256 amount);
    event TreasuryClaim(uint256 amount);
    event Unpause(uint256 indexed epoch);

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "Not admin");
        _;
    }

    modifier onlyAdminOrOperator() {
        require(msg.sender == adminAddress || msg.sender == operatorAddress, "Not operator/admin");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operatorAddress, "Not operator");
        _;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    constructor(
        IERC20 _token,
        address _oracleAddress,
        address _adminAddress,
        address _operatorAddress,
        uint256 _intervalSeconds,
        uint256 _bufferSeconds,
        uint256 _minBetAmount,
        uint256 _oracleUpdateAllowance,
        uint256 _treasuryFee
    ) {
        require(_treasuryFee <= MAX_TREASURY_FEE, "Treasury fee too high");

        token = _token;
        oracle = AggregatorV3Interface(_oracleAddress);
        adminAddress = _adminAddress;
        operatorAddress = _operatorAddress;
        intervalSeconds = _intervalSeconds;
        bufferSeconds = _bufferSeconds;
        minBetAmount = _minBetAmount;
        oracleUpdateAllowance = _oracleUpdateAllowance;
        treasuryFee = _treasuryFee;
    }

    function betBear(uint256 epoch, uint256 _amount) external whenNotPaused nonReentrant notContract {
        require(epoch == currentEpoch, "Bet is too early/late");
        require(_bettable(epoch), "Round not bettable");
        require(_amount >= minBetAmount, "Bet amount must be greater than minBetAmount");
        require(ledger[epoch][msg.sender].amount == 0, "Can only bet once per round");

        token.safeTransferFrom(msg.sender, address(this), _amount);

        Round storage round = rounds[epoch];
        round.totalAmount += _amount;
        round.bearAmount += _amount;

        BetInfo storage betInfo = ledger[epoch][msg.sender];
        betInfo.position = Position.Bear;
        betInfo.amount = _amount;
        userRounds[msg.sender].push(epoch);

        emit BetBear(msg.sender, epoch, _amount);
    }

    function betBull(uint256 epoch, uint256 _amount) external whenNotPaused nonReentrant notContract {
        require(epoch == currentEpoch, "Bet is too early/late");
        require(_bettable(epoch), "Round not bettable");
        require(_amount >= minBetAmount, "Bet amount must be greater than minBetAmount");
        require(ledger[epoch][msg.sender].amount == 0, "Can only bet once per round");

        token.safeTransferFrom(msg.sender, address(this), _amount);

        Round storage round = rounds[epoch];
        round.totalAmount += _amount;
        round.bullAmount += _amount;

        BetInfo storage betInfo = ledger[epoch][msg.sender];
        betInfo.position = Position.Bull;
        betInfo.amount = _amount;
        userRounds[msg.sender].push(epoch);

        emit BetBull(msg.sender, epoch, _amount);
    }

    function claim(uint256[] calldata epochs) external nonReentrant notContract {
        uint256 reward;

        for (uint256 i = 0; i < epochs.length; i++) {
            require(rounds[epochs[i]].startTimestamp != 0, "Round has not started");
            require(block.timestamp > rounds[epochs[i]].closeTimestamp, "Round has not ended");

            uint256 addedReward = 0;

            if (rounds[epochs[i]].oracleCalled) {
                require(claimable(epochs[i], msg.sender), "Not eligible for claim");
                Round memory round = rounds[epochs[i]];
                addedReward = (ledger[epochs[i]][msg.sender].amount * round.rewardAmount) / round.rewardBaseCalAmount;
            } else {
                require(refundable(epochs[i], msg.sender), "Not eligible for refund");
                addedReward = ledger[epochs[i]][msg.sender].amount;
            }

            ledger[epochs[i]][msg.sender].claimed = true;
            reward += addedReward;

            emit Claim(msg.sender, epochs[i], addedReward);
        }

        if (reward > 0) {
            token.safeTransfer(msg.sender, reward);
        }
    }

    function executeRound() external whenNotPaused onlyOperator {
        require(
            genesisStartOnce && genesisLockOnce,
            "Can only run after genesisStartRound and genesisLockRound is triggered"
        );

        (uint80 currentRoundId, int256 currentPrice) = _getPriceFromOracle();

        oracleLatestRoundId = uint256(currentRoundId);

        _safeLockRound(currentEpoch, currentRoundId, currentPrice);
        _safeEndRound(currentEpoch - 1, currentRoundId, currentPrice);
        _calculateRewards(currentEpoch - 1);

        currentEpoch++;
        _safeStartRound(currentEpoch);
    }

    function genesisLockRound() external whenNotPaused onlyOperator {
        require(genesisStartOnce, "Can only run after genesisStartRound is triggered");
        require(!genesisLockOnce, "Can only run genesisLockRound once");

        (uint80 currentRoundId, int256 currentPrice) = _getPriceFromOracle();

        oracleLatestRoundId = uint256(currentRoundId);

        _safeLockRound(currentEpoch, currentRoundId, currentPrice);

        currentEpoch++;
        _startRound(currentEpoch);
        genesisLockOnce = true;
    }

    function genesisStartRound() external whenNotPaused onlyOperator {
        require(!genesisStartOnce, "Can only run genesisStartRound once");

        currentEpoch++;
        _startRound(currentEpoch);
        genesisStartOnce = true;
    }

    function pause() external whenNotPaused onlyAdminOrOperator {
        _pause();

        emit Pause(currentEpoch);
    }

    function unpause() external whenPaused onlyAdmin {
        genesisStartOnce = false;
        genesisLockOnce = false;
        _unpause();

        emit Unpause(currentEpoch);
    }

    function setBufferAndIntervalSeconds(uint256 _bufferSeconds, uint256 _intervalSeconds) external onlyAdmin {
        require(_bufferSeconds < _intervalSeconds, "bufferSeconds must be less than intervalSeconds");
        bufferSeconds = _bufferSeconds;
        intervalSeconds = _intervalSeconds;

        emit NewBufferAndIntervalSeconds(_bufferSeconds, _intervalSeconds);
    }

    function setMinBetAmount(uint256 _minBetAmount) external onlyAdmin {
        minBetAmount = _minBetAmount;

        emit NewMinBetAmount(currentEpoch, _minBetAmount);
    }

    function setTreasuryFee(uint256 _treasuryFee) external onlyAdmin {
        require(_treasuryFee <= MAX_TREASURY_FEE, "treasuryFee must be less than MAX_TREASURY_FEE");
        treasuryFee = _treasuryFee;

        emit NewTreasuryFee(currentEpoch, _treasuryFee);
    }

    function setAdmin(address _adminAddress) external onlyAdmin {
        require(_adminAddress != address(0), "Cannot be zero address");
        adminAddress = _adminAddress;

        emit NewAdminAddress(_adminAddress);
    }

    function setOperator(address _operatorAddress) external onlyAdmin {
        require(_operatorAddress != address(0), "Cannot be zero address");
        operatorAddress = _operatorAddress;

        emit NewOperatorAddress(_operatorAddress);
    }

    function setOracle(address _oracle) external onlyAdmin {
        require(_oracle != address(0), "Cannot be zero address");
        oracle = AggregatorV3Interface(_oracle);

        emit NewOracle(_oracle);
    }

    function setOracleUpdateAllowance(uint256 _oracleUpdateAllowance) external onlyAdmin {
        oracleUpdateAllowance = _oracleUpdateAllowance;

        emit NewOracleUpdateAllowance(_oracleUpdateAllowance);
    }

    function claimTreasury() external nonReentrant onlyAdmin {
        uint256 currentTreasuryAmount = treasuryAmount;
        treasuryAmount = 0;
        token.safeTransfer(adminAddress, currentTreasuryAmount);

        emit TreasuryClaim(currentTreasuryAmount);
    }

    function recoverToken(address _token, uint256 amount) external onlyOwner {
        IERC20(_token).safeTransfer(msg.sender, amount);

        emit TokenRecovery(_token, amount);
    }

    function _bettable(uint256 epoch) internal view returns (bool) {
        return
            rounds[epoch].startTimestamp != 0 &&
            rounds[epoch].lockTimestamp != 0 &&
            block.timestamp > rounds[epoch].startTimestamp &&
            block.timestamp < rounds[epoch].lockTimestamp;
    }

    function _calculateRewards(uint256 epoch) internal {
        require(rewardRatePerPeriod > 0, "rewardRatePerPeriod must be greater than zero");
        require(
            rounds[epoch].rewardAmount == 0 && rounds[epoch].rewardBaseCalAmount == 0,
            "Rewards calculated"
        );

        Round storage round = rounds[epoch];
        uint256 rewardBaseCalAmount;
        uint256 rewardAmount;
        uint256 treasuryAmt;

        if (round.closePrice > round.lockPrice) {
            rewardBaseCalAmount = round.bullAmount;
            rewardAmount = round.totalAmount * (10000 - treasuryFee) / 10000;
            treasuryAmt = round.totalAmount - rewardAmount;
        } else {
            rewardBaseCalAmount = round.bearAmount;
            rewardAmount = round.totalAmount * (10000 - treasuryFee) / 10000;
            treasuryAmt = round.totalAmount - rewardAmount;
        }

        round.rewardBaseCalAmount = rewardBaseCalAmount;
        round.rewardAmount = rewardAmount;

        treasuryAmount += treasuryAmt;

        emit RewardsCalculated(epoch, rewardBaseCalAmount, rewardAmount, treasuryAmt);
    }

    function _safeStartRound(uint256 epoch) internal {
        require(genesisStartOnce, "Can only run after genesisStartRound is triggered");

        Round storage round = rounds[epoch];
        round.startTimestamp = block.timestamp;
        round.lockTimestamp = block.timestamp + intervalSeconds;
        round.closeTimestamp = block.timestamp + (2 * intervalSeconds);

        emit StartRound(epoch);
    }

    function _startRound(uint256 epoch) internal {
        Round storage round = rounds[epoch];
        round.startTimestamp = block.timestamp;
        round.lockTimestamp = block.timestamp + intervalSeconds;
        round.closeTimestamp = block.timestamp + (2 * intervalSeconds);

        emit StartRound(epoch);
    }

    function _safeEndRound(
        uint256 epoch,
        uint80 roundId,
        int256 price
    ) internal {
        require(rounds[epoch].lockTimestamp != 0, "Can only end round after round has locked");
        require(block.timestamp >= rounds[epoch].closeTimestamp, "Can only end round after closeTimestamp");
        require(
            block.timestamp <= rounds[epoch].closeTimestamp + bufferSeconds,
            "Can only end round within bufferSeconds"
        );

        Round storage round = rounds[epoch];
        round.closePrice = price;
        round.closeOracleId = roundId;
        round.oracleCalled = true;

        emit EndRound(epoch, roundId, price);
    }

    function _safeLockRound(
        uint256 epoch,
        uint80 roundId,
        int256 price
    ) internal {
        require(
            rounds[epoch].startTimestamp != 0,
            "Can only lock round after round has started"
        );
        require(
            block.timestamp >= rounds[epoch].lockTimestamp,
            "Can only lock round after lockTimestamp"
        );
        require(
            block.timestamp <= rounds[epoch].lockTimestamp + bufferSeconds,
            "Can only lock round within bufferSeconds"
        );

        Round storage round = rounds[epoch];
        round.lockPrice = price;
        round.lockOracleId = roundId;

        emit LockRound(epoch, roundId, price);
    }

    function _getPriceFromOracle() internal view returns (uint80, int256) {
        (uint80 roundId, int256 price, , , ) = oracle.latestRoundData();
        return (roundId, price);
    }

    function claimable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];

        if (round.lockPrice == round.closePrice) {
            return false;
        }
        return
            round.oracleCalled &&
            ((round.closePrice > round.lockPrice && betInfo.position == Position.Bull) ||
                (round.closePrice < round.lockPrice && betInfo.position == Position.Bear));
    }

    function refundable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];

        return !round.oracleCalled && block.timestamp > round.closeTimestamp + bufferSeconds;
    }

    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}
