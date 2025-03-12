// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./RNTERC20.sol";
import "./ReRNTERC20.sol";

contract RNTStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for RNTERC20;
    using SafeERC20 for ReRNTERC20;

    struct StakeInfo {
        uint256 stakedAmount;      // 质押数量
        uint256 unclaimedRewards;  // 未领取奖励
        uint256 lastUpdateTime;    // 上次更新时间
    }

    struct UnlockInfo {
        uint256 amount;           // 解锁数量
        uint256 startTime;        // 开始时间
    }

    RNTERC20 public rntToken;      // RNT token
    ReRNTERC20 public esRntToken;  // esRNT token

    //RNT 储备变量
    uint256 public rntReserve;

    uint256 public constant LOCK_DURATION = 30 days;  // 锁定期30天
    uint256 public constant REWARD_RATE = 1e18;    // 每天每个RNT获得1个esRNT
    
    // 总质押量
    uint256 public totalStaked;
    
    mapping(address => StakeInfo) public stakes;
    mapping(address => UnlockInfo) public unlocks;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event TokenLocked(address indexed user, uint256 amount);
    event TokenUnlocked(address indexed user, uint256 amount, uint256 penalty);
    event RNTDeposited(uint256 amount);

    constructor(address _rntToken, address _esRntToken) Ownable(msg.sender) {
        rntToken = RNTERC20(_rntToken);
        esRntToken = ReRNTERC20(_esRntToken);
    }

    modifier updateReward(address _account) {
        StakeInfo storage stakeInfo = stakes[_account];
        if (stakeInfo.stakedAmount > 0) {
            uint256 timeElapsed = block.timestamp - stakeInfo.lastUpdateTime;
            uint256 reward = (stakeInfo.stakedAmount * timeElapsed * REWARD_RATE) / (1 days);
            stakeInfo.unclaimedRewards += reward;
        }
        stakeInfo.lastUpdateTime = block.timestamp;
        _;
    }

    // 质押
    function stake(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        require(_amount > 0, "Cannot stake 0");
        
        stakes[msg.sender].stakedAmount += _amount;
        totalStaked += _amount;
        rntToken.safeTransferFrom(msg.sender, address(this), _amount);
        
        emit Staked(msg.sender, _amount);
    }

    // 解除质押
    function unstake(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        require(_amount > 0, "Cannot unstake 0");
        require(stakes[msg.sender].stakedAmount >= _amount, "Insufficient balance");

        stakes[msg.sender].stakedAmount -= _amount;
        totalStaked -= _amount;
        rntToken.safeTransfer(msg.sender, _amount);

        emit Unstaked(msg.sender, _amount);
    }

    // 领取奖励
    function claimReward() external nonReentrant updateReward(msg.sender) {
        uint256 reward = stakes[msg.sender].unclaimedRewards;
        require(reward > 0, "No reward");
        
        stakes[msg.sender].unclaimedRewards = 0;
        esRntToken.mint(msg.sender, reward);
        
        emit RewardClaimed(msg.sender, reward);
    }

    // 锁定esRNT
    function lockTokens(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Cannot lock 0");
        require(unlocks[msg.sender].amount == 0, "Already has locked tokens");
        
        esRntToken.safeTransferFrom(msg.sender, address(this), _amount);
        unlocks[msg.sender] = UnlockInfo({
            amount: _amount,
            startTime: block.timestamp
        });
        
        emit TokenLocked(msg.sender, _amount);
    }

    // 存入 RNT
    function depositRNT(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Cannot deposit 0");
        rntToken.safeTransferFrom(msg.sender, address(this), _amount);
        rntReserve += _amount;
        emit RNTDeposited(_amount);
    }

    // 解锁
    function unlockTokens() external nonReentrant {
        UnlockInfo storage lockInfo = unlocks[msg.sender];
        require(lockInfo.amount > 0, "No tokens locked");

        uint256 timePassed = block.timestamp - lockInfo.startTime;
        uint256 amount = lockInfo.amount;
        uint256 penalty = 0;

        if (timePassed < LOCK_DURATION) {
            uint256 remainingTime = LOCK_DURATION - timePassed;
            penalty = (amount * remainingTime) / LOCK_DURATION;
            amount -= penalty;
        }

        require(rntReserve >= amount, "Insufficient RNT reserve");
        
        lockInfo.amount = 0;
        rntReserve -= amount;  
        
        if (penalty > 0) {
            esRntToken.burnFrom(address(this), penalty);
        }
        
        rntToken.safeTransfer(msg.sender, amount);
        
        emit TokenUnlocked(msg.sender, amount, penalty);
    }

    // 查看待领取奖励
    function pendingReward(address _user) external view returns (uint256) {
        StakeInfo storage stakeInfo = stakes[_user];
        if (stakeInfo.stakedAmount == 0) return stakeInfo.unclaimedRewards;
        
        uint256 timeElapsed = block.timestamp - stakeInfo.lastUpdateTime;
        uint256 newRewards = (stakeInfo.stakedAmount * timeElapsed * REWARD_RATE) / (1 days);
        return stakeInfo.unclaimedRewards + newRewards;
    }

    // 获取用户质押份额
    function getUserShare(address _user) external view returns (uint256) {
        if (totalStaked == 0) return 0;
        return (stakes[_user].stakedAmount * REWARD_RATE) / totalStaked;
    }
} 