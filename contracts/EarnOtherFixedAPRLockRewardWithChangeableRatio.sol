//contracts/EarnOtherFixedAPRLockRewardWithChangeableRatio.sol
// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract EarnOtherFixedAPRLockRewardWithChangeableRatio is Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for ERC20;

  /// @dev define from constructor
  uint256 private constant BLOCK_PER_DAY = 28800;
  uint256 private constant DAY_PER_YEAR = 365;
  uint256 private constant RATIO_PRECISION = 1e18;
  uint256 private constant PERCENTAGE_PRECISION = 1e2;
  uint256 private constant APR_PRECISION = 1e18;

  /// @dev define from constructor
  uint256 public immutable startBlock;
  uint256 public immutable endBlock;
  uint256 public immutable claimableBlock;
  bool public isUpdateTokenRatio;
  ERC20 public immutable stakedToken;
  ERC20 public immutable rewardToken;

  /// @dev define fixed APR, ratio and reward attrs from constructor
  uint256 public immutable apr;
  uint256 public immutable cap;
  uint256 private rewardPerBlock;
  uint256 private rewardPerBlockPrecisionFactor;
  uint256 public tokenRatio;
  uint256 private preActualTokenRatio;
  uint256 private actualTokenRatio;

  /// @dev Pool debt total staked from all users
  uint256 public rewardDebt;
  uint256 public totalStaked;

  /// @dev Info of each user that stakes tokens (stakedToken)
  mapping(address => UserInfo) public userInfo;

  struct UserInfo {
    uint256 amount;
    uint256 rewards;
    uint256 lastRewardBlock;
  }

  event Deposit(address indexed user, uint256 amount);
  event Withdraw(address indexed user, uint256 amount, uint256 rewards);
  event EmergencyWithdraw(address indexed user, uint256 amount);
  event RecoveryReward(address tokenRecovered, uint256 amount);
  event UpdateTokenRatio(uint256 ratio, uint256 rewardDebt);

  constructor(
    ERC20 _stakedToken,
    ERC20 _rewardToken,
    uint256 _cap,
    uint256 _apr,
    uint256 _tokenRatio,
    uint256 _startBlock,
    uint256 _endBlock,
    address _admin
  ) {
    stakedToken = _stakedToken;
    rewardToken = _rewardToken;
    cap = _cap;
    apr = _apr;
    tokenRatio = _tokenRatio;
    startBlock = _startBlock;
    endBlock = _endBlock;
    claimableBlock = _endBlock;
    actualTokenRatio = _tokenRatio;

    require(_rewardToken != _stakedToken, "the staked token and the reward token should not be the same");

    if (_rewardToken.decimals() > _stakedToken.decimals()) {
      actualTokenRatio = _tokenRatio.mul(10**(_rewardToken.decimals() - _stakedToken.decimals()));
    }

    if (_rewardToken.decimals() < _stakedToken.decimals()) {
      actualTokenRatio = _tokenRatio.div(10**(_stakedToken.decimals() - _rewardToken.decimals()));
    }

    rewardPerBlock = _apr.mul(actualTokenRatio).div(BLOCK_PER_DAY.mul(DAY_PER_YEAR));
    rewardPerBlockPrecisionFactor = RATIO_PRECISION.mul(PERCENTAGE_PRECISION).mul(APR_PRECISION);

    transferOwnership(_admin);
  }

  function deposit(uint256 _amount) external nonReentrant {
    require(block.number >= startBlock, "not allow before start period");
    require(block.number < endBlock, "not allow after end period");
    require(totalStaked < cap, "pool capacity is reached");
    UserInfo storage user = userInfo[msg.sender];

    uint256 remaining = cap.sub(totalStaked);
    uint256 preAmount = stakedToken.balanceOf(address(this));

    if (remaining < _amount) {
      stakedToken.safeTransferFrom(address(msg.sender), address(this), remaining);
    } else {
      stakedToken.safeTransferFrom(address(msg.sender), address(this), _amount);
    }

    uint256 postAmount = stakedToken.balanceOf(address(this));
    uint256 actualAmount = postAmount.sub(preAmount);
    totalStaked = totalStaked.add(actualAmount);
    uint256 lastRewardBlock = block.number;

    rewardDebt = rewardDebt.add(
      actualAmount.mul((endBlock.sub(lastRewardBlock)).mul(rewardPerBlock)).div(rewardPerBlockPrecisionFactor)
    );

    require(rewardDebt <= rewardToken.balanceOf(address(this)), "insufficient reward reserve");

    if (user.amount > 0 && block.number > startBlock) {
      uint256 rewards = _calculateReward(user.amount, user.lastRewardBlock);
      user.rewards = user.rewards.add(rewards);
    }

    user.amount = user.amount.add(actualAmount);
    user.lastRewardBlock = lastRewardBlock;

    emit Deposit(msg.sender, actualAmount);
  }

  function pendingReward(address _for) external view returns (uint256) {
    require(_for != address(0), "bad address");
    UserInfo storage user = userInfo[_for];

    uint256 rewards = _calculateReward(user.amount, user.lastRewardBlock);
    uint256 userRewards = user.rewards.add(rewards);

    if (isUpdateTokenRatio) {
      userRewards = (user.rewards.mul(actualTokenRatio).div(preActualTokenRatio)).add(rewards);
    }

    return userRewards;
  }

  function withdraw() external nonReentrant {
    require(block.number > endBlock, "not allow before end period");
    require(isUpdateTokenRatio, "token ratio is not update yet");
    UserInfo storage user = userInfo[msg.sender];

    if (user.amount > 0) {
      uint256 withdrawAmount = user.amount;

      // re-calculate user reward using new token ratio
      user.rewards = user.rewards.mul(actualTokenRatio).div(preActualTokenRatio);

      uint256 rewards = _calculateReward(user.amount, user.lastRewardBlock);
      rewards = user.rewards.add(rewards);

      // for last user who withdraw
      if (rewards > rewardDebt) {
        rewards = rewardDebt;
      }

      rewardToken.safeTransfer(msg.sender, rewards);
      stakedToken.safeTransfer(msg.sender, withdrawAmount);

      user.amount = 0;
      user.rewards = 0;
      user.lastRewardBlock = endBlock;

      totalStaked = totalStaked.sub(withdrawAmount);
      rewardDebt = rewardDebt.sub(rewards);

      emit Withdraw(msg.sender, withdrawAmount, rewards);
    }
  }

  function emergencyWithdraw() external nonReentrant {
    require(block.number > endBlock, "not allow before end period");
    UserInfo storage user = userInfo[msg.sender];

    if (user.amount > 0) {
      uint256 withdrawAmount = user.amount;
      uint256 rewards = _calculateReward(user.amount, user.lastRewardBlock);
      uint256 userRewards = user.rewards.add(rewards);

      if (isUpdateTokenRatio) {
        userRewards = (user.rewards.mul(actualTokenRatio).div(preActualTokenRatio)).add(rewards);
      }

      stakedToken.safeTransfer(msg.sender, withdrawAmount);

      user.amount = 0;
      user.rewards = 0;
      user.lastRewardBlock = endBlock;

      totalStaked = totalStaked.sub(withdrawAmount);
      rewardDebt = rewardDebt.sub(userRewards);

      emit EmergencyWithdraw(msg.sender, withdrawAmount);
    }
  }

  function recoveryReward(address _for) external onlyOwner {
    require(block.number > endBlock, "not allow before end period");

    uint256 rewardBalance = rewardToken.balanceOf(address(this));

    if (rewardBalance > rewardDebt) {
      uint256 transferAmount = rewardBalance.sub(rewardDebt);
      rewardToken.safeTransfer(_for, transferAmount);

      emit RecoveryReward(_for, transferAmount);
    }
  }

  function updateTokenRatio(uint256 _ratio) external onlyOwner {
    require(block.number > endBlock, "not allow before end period");
    require(!isUpdateTokenRatio, "token ratio is already updated");

    preActualTokenRatio = actualTokenRatio;

    tokenRatio = _ratio;
    actualTokenRatio = _ratio;

    if (rewardToken.decimals() > stakedToken.decimals()) {
      actualTokenRatio = tokenRatio.mul(10**(rewardToken.decimals() - stakedToken.decimals()));
    }

    if (rewardToken.decimals() < stakedToken.decimals()) {
      actualTokenRatio = tokenRatio.div(10**(stakedToken.decimals() - rewardToken.decimals()));
    }

    rewardPerBlock = apr.mul(actualTokenRatio).div(BLOCK_PER_DAY.mul(DAY_PER_YEAR));
    rewardDebt = rewardDebt.mul(actualTokenRatio).div(preActualTokenRatio);

    isUpdateTokenRatio = true;

    emit UpdateTokenRatio(_ratio, rewardDebt);
  }

  function _calculateReward(uint256 _amount, uint256 _fromBlock) internal view returns (uint256) {
    uint256 toBlock = block.number;

    if (toBlock <= _fromBlock) {
      return 0;
    }

    if (toBlock > endBlock) {
      toBlock = endBlock;
    }

    uint256 blocks = toBlock.sub(_fromBlock);

    return _amount.mul(blocks.mul(rewardPerBlock)).div(rewardPerBlockPrecisionFactor);
  }
}
