// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/RNTStaking.sol";
import "../src/RNTERC20.sol";
import "../src/ReRNTERC20.sol";

contract RNTStakingTest is Test {
    RNTStaking public staking;
    RNTERC20 public rntToken;
    ReRNTERC20 public esRntToken;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    
    uint256 public constant INITIAL_MINT = 10000e18;  // 10000 tokens
    uint256 public constant STAKE_AMOUNT = 100e18;    // 100 tokens
    uint256 public constant ONE_DAY = 1 days;
    uint256 public constant REWARD_RATE = 1e18;

    function setUp() public {
        // 部署合约
        rntToken = new RNTERC20();
        esRntToken = new ReRNTERC20();
        staking = new RNTStaking(address(rntToken), address(esRntToken));
        
        // 铸造初始代币
        rntToken.mint(alice, STAKE_AMOUNT);
        rntToken.mint(bob, STAKE_AMOUNT);


        // 给测试合约铸造代币
        rntToken.mint(address(this), INITIAL_MINT);
        
        // 存入RNT到质押合约
        rntToken.approve(address(staking), INITIAL_MINT);
        staking.depositRNT(INITIAL_MINT);
        
        // 设置权限
        esRntToken.transferOwnership(address(staking));
        
        // 授权
        vm.prank(alice);
        rntToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        rntToken.approve(address(staking), type(uint256).max);
    }

    function test_Stake() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);
        
        (uint256 stakedAmount,,) = staking.stakes(alice);
        assertEq(stakedAmount, STAKE_AMOUNT);
    }

    function test_Rewards() public {
        // 1. 先质押代币
        vm.startPrank(alice);
        staking.stake(STAKE_AMOUNT);
        
        // 记录初始时间点
        uint256 stakeTime = block.timestamp;
        
        // 2. 前进1天时间
        skip(ONE_DAY);
        
        // 3. 检查待领取奖励
        uint256 expectedReward = (STAKE_AMOUNT * ONE_DAY * REWARD_RATE) / ONE_DAY;  // 应该等于 STAKE_AMOUNT
        uint256 pendingReward = staking.pendingReward(alice);
        assertEq(pendingReward, expectedReward, "Pending reward calculation error");

        // 4. 领取奖励
        uint256 beforeBalance = esRntToken.balanceOf(alice);
        staking.claimReward();
        uint256 afterBalance = esRntToken.balanceOf(alice);

        // 5. 验证实际收到的奖励
        assertEq(afterBalance - beforeBalance, expectedReward, "Claimed reward amount error");
        
        // 6. 验证奖励已被重置
        (,uint256 unclaimedRewards,) = staking.stakes(alice);
        assertEq(unclaimedRewards, 0, "Rewards not reset after claim");

        vm.stopPrank();
    }

    function test_Lock() public {
        vm.startPrank(alice);
        
        // 质押并等待1天获得奖励
        staking.stake(STAKE_AMOUNT);
        skip(ONE_DAY);
        staking.claimReward();

        // 锁定50个esRNT
        uint256 lockAmount = 50e18;
        esRntToken.approve(address(staking), lockAmount);
        staking.lockTokens(lockAmount);

        // 检查锁定记录
        (uint256 amount, uint256 startTime) = staking.unlocks(alice);
        assertEq(amount, lockAmount);
        
        vm.stopPrank();
    }

    function test_Unlock() public {
        vm.startPrank(alice);
        
        // 记录初始余额
        uint256 initialBalance = rntToken.balanceOf(alice);
        
        // 质押并获得奖励
        staking.stake(STAKE_AMOUNT);
        skip(ONE_DAY);
        staking.claimReward();

        // 锁定50个esRNT
        uint256 lockAmount = 50e18;
        esRntToken.approve(address(staking), lockAmount);
        staking.lockTokens(lockAmount);

        // 等待30天后解锁
        skip(30 days);
        staking.unlockTokens();

        // 检查获得的RNT (初始余额 - 质押金额 + 解锁金额)
        assertEq(
            rntToken.balanceOf(alice), 
            initialBalance - STAKE_AMOUNT + lockAmount
        );
        
        vm.stopPrank();
    }

    function test_EarlyUnlock() public {
        vm.startPrank(alice);
        
        // 记录初始余额
        uint256 initialBalance = rntToken.balanceOf(alice);
        
        // 质押并获得奖励
        staking.stake(STAKE_AMOUNT);
        skip(ONE_DAY);
        staking.claimReward();

        // 锁定50个esRNT
        uint256 lockAmount = 50e18;
        esRntToken.approve(address(staking), lockAmount);
        staking.lockTokens(lockAmount);

        // 15天后解锁（一半时间）
        skip(15 days);
        staking.unlockTokens();

        // 检查获得的RNT (初始余额 - 质押金额 + 解锁金额的一半)
        assertEq(
            rntToken.balanceOf(alice), 
            initialBalance - STAKE_AMOUNT + lockAmount/2
        );
        
        vm.stopPrank();
    }

    function test_RevertWhen_StakingZero() public {
        vm.prank(alice);
        vm.expectRevert("Cannot stake 0");
        staking.stake(0);
    }

    function test_RevertWhen_LockingZero() public {
        vm.prank(alice);
        vm.expectRevert("Cannot lock 0");
        staking.lockTokens(0);
    }

    function test_RevertWhen_InsufficientReserve() public {
        vm.startPrank(alice);
        
        // 质押并获得奖励
        staking.stake(STAKE_AMOUNT);
        skip(ONE_DAY);
        staking.claimReward();

        // 锁定大量esRNT
        uint256 largeAmount = INITIAL_MINT * 2;
        vm.mockCall(
            address(esRntToken),
            abi.encodeWithSelector(esRntToken.transferFrom.selector),
            abi.encode(true)
        );
        staking.lockTokens(largeAmount);

        // 等待锁定期结束
        skip(30 days);
        
        // 应该因为储备不足而失败
        vm.expectRevert("Insufficient RNT reserve");
        staking.unlockTokens();
        
        vm.stopPrank();
    }
} 