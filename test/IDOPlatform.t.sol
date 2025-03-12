// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";
import {IDOPlatform} from "../src/IDOPlatform.sol";
import {RNTERC20} from "../src/RNTERC20.sol";
import {ReRNTERC20} from "../src/ReRNTERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract IDOPlatformTest is Test {

    struct Presale {
        IERC20 token;
        uint256 price;            // wei per token
        uint256 targetAmount;     // ETH target
        uint256 capAmount;        // ETH cap
        uint256 maxPerTx;        // 单笔最大购买量
        uint256 maxPerAddress;   // 单地址最大购买量
        uint256 duration;         // in seconds
        uint256 startTime;
        uint256 totalRaised;
        bool isActive;
        mapping(address => uint256) contributions;
        mapping(address => uint256) claimedTokens;
    }

    IDOPlatform public idoPlatform;
    RNTERC20 public rntToken;
    ReRNTERC20 public esRntToken;
    
    address public platformOwner = makeAddr("platformOwner");
    address public creator = makeAddr("creator");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    
    uint256 public constant PLATFORM_FEE = 300; // 3%
    uint256 public constant TOTAL_TOKENS_FOR_SALE = 1_000_000 ether; // 100万代币用于预售
    uint256 public constant TARGET_AMOUNT = 100 ether;   // 最低募集 100 ETH
    uint256 public constant CAP_AMOUNT = 200 ether;      // 最高募集 200 ETH
    uint256 public constant MIN_PER_TX = 0.01 ether;     // 单笔最少 0.01 ETH
    uint256 public constant MAX_PER_ADDRESS = 5 ether;   // 单地址最多 5 ETH
    uint256 public constant DURATION = 7 days;
    uint256 public constant INITIAL_SUPPLY = 10_000_000 ether; // 1000万 RNT 总供应

    event PresaleCreated(uint256 indexed id, address token, uint256 startTime);
    event PresaleEnded(uint256 indexed id, bool success);
    event Contributed(uint256 indexed id, address indexed user, uint256 amount);

    function setUp() public {
        // 部署平台合约
        vm.startPrank(platformOwner);
        idoPlatform = new IDOPlatform(PLATFORM_FEE);
        vm.stopPrank();

       

        // 部署质押合约并授权
        vm.startPrank(creator);
         // 部署代币合约
        rntToken = new RNTERC20();
        esRntToken = new ReRNTERC20();

        rntToken.mint(creator, INITIAL_SUPPLY);
        rntToken.approve(address(idoPlatform), TOTAL_TOKENS_FOR_SALE);
        vm.stopPrank();
      

        // 给测试用户转 ETH
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    
    function test_DeploymentState() public {
        assertEq(address(idoPlatform.owner()), platformOwner);
        assertEq(idoPlatform.platformFee(), PLATFORM_FEE);
        assertEq(rntToken.balanceOf(creator), INITIAL_SUPPLY);
        assertEq(rntToken.allowance(creator, address(idoPlatform)), TOTAL_TOKENS_FOR_SALE);
    }

    // 创建预售
    function test_CreatePresale() public {
        vm.startPrank(creator);
        
        vm.expectEmit(true, true, false, true);
        emit PresaleCreated(1, address(rntToken), block.timestamp);
        
        uint256 presaleId = idoPlatform.createPresale(
            address(rntToken),
            TOTAL_TOKENS_FOR_SALE,
            TARGET_AMOUNT,
            CAP_AMOUNT,
            MIN_PER_TX,
            MAX_PER_ADDRESS,
            DURATION
        );
        
        assertEq(presaleId, 1, "Invalid presale ID");
        assertEq(idoPlatform.presaleCount(), 1, "Invalid presale count");
        
        vm.stopPrank();
    }

    function test_RevertWhen_InvalidPresaleId() public {
        vm.expectRevert("Invalid presale");
        idoPlatform.contribute{value: 0.01 ether}(999);
    }

    function test_RevertWhen_NotCreator() public {
        uint256 presaleId = _createPresale();
        
        vm.warp(block.timestamp + DURATION + 1);
        
        vm.expectRevert("Not creator");
        vm.prank(user1);
        idoPlatform.withdrawFunds(presaleId);
    }

    function test_ContributeWithinLimits() public {
        uint256 presaleId = _createPresale();

        vm.startPrank(user1);
        idoPlatform.contribute{value: 0.01 ether}(presaleId);
        vm.stopPrank();

        (uint256 totalRaised,, bool isSuccessful) = idoPlatform.getPresaleInfo(presaleId);
        assertEq(totalRaised, 0.01 ether, "Invalid total raised");
        assertFalse(isSuccessful, "Should not be successful yet");
    }

    function test_RevertWhen_BelowMinTx() public {
        uint256 presaleId = _createPresale();

        vm.expectRevert("Exceeds tx limit");
        vm.prank(user1);
        idoPlatform.contribute{value: 0.009 ether}(presaleId);
    }

    function test_RevertWhen_ExceedAddressLimit() public {
        uint256 presaleId = _createPresale();

        vm.startPrank(user1);
        idoPlatform.contribute{value: 5 ether}(presaleId);
        
        vm.expectRevert("Exceeds address limit");
        idoPlatform.contribute{value: 1 ether}(presaleId);
        vm.stopPrank();
    }

    // 成功预售
    function test_SuccessfulPresale() public {
        uint256 presaleId = _createPresale();

        // 转移代币到平台合约
        vm.startPrank(creator);
        rntToken.transfer(address(idoPlatform), TOTAL_TOKENS_FOR_SALE);
        vm.stopPrank();

        // user1 投资 1 ETH (占总募集金额的 1%)
        vm.startPrank(user1);
        idoPlatform.contribute{value: 1 ether}(presaleId);
        vm.stopPrank();

        // 其他用户投资达到目标金额
        for(uint i = 0; i < 99; i++) {
            address user = makeAddr(string(abi.encodePacked("user", i)));
            vm.deal(user, 1 ether);
            vm.prank(user);
            idoPlatform.contribute{value: 1 ether}(presaleId);
        }

        // 等待预售结束
        vm.warp(block.timestamp + DURATION + 1);

        // user1 领取代币
        vm.prank(user1);
        idoPlatform.claim(presaleId);

        // user1 投资了 1 ETH，总募集 100 ETH
        // 所以应该获得 1% 的代币 = 10,000 RNT
        assertEq(rntToken.balanceOf(user1), 10_000 ether, "Invalid token amount");

        // 创建者提取资金
        uint256 creatorBalanceBefore = creator.balance;
        uint256 platformOwnerBalanceBefore = platformOwner.balance;

        vm.prank(creator);
        idoPlatform.withdrawFunds(presaleId);

        // 验证提取金额（创建者应该收到97%的资金，平台收到3%）
        assertEq(creator.balance - creatorBalanceBefore, 97 ether, "Invalid creator amount");
        assertEq(platformOwner.balance - platformOwnerBalanceBefore, 3 ether, "Invalid platform fee");
    }

    function test_FailedPresale() public {
        uint256 presaleId = _createPresale();

        // 只有少量投资
        vm.startPrank(user1);
        idoPlatform.contribute{value: 1 ether}(presaleId);
        vm.stopPrank();

        // 等待预售结束
        vm.warp(block.timestamp + DURATION + 1);

        // 用户可以申请退款
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        idoPlatform.claim(presaleId);
        
        assertEq(user1.balance - balanceBefore, 1 ether, "Refund amount incorrect");
    }

    function test_RevertWhen_AlreadyClaimed() public {
        uint256 presaleId = _createPresale();

        // 用户投资
        vm.startPrank(user1);
        idoPlatform.contribute{value: 1 ether}(presaleId);
        vm.stopPrank();

        // 等待预售结束
        vm.warp(block.timestamp + DURATION + 1);

        // 第一次领取成功
        vm.prank(user1);
        idoPlatform.claim(presaleId);

        // 第二次领取失败
        vm.expectRevert("Already claimed");
        vm.prank(user1);
        idoPlatform.claim(presaleId);
    }

    function test_RevertWhen_PresaleNotEnded() public {
        uint256 presaleId = _createPresale();

        vm.expectRevert("Presale not ended");
        vm.prank(user1);
        idoPlatform.claim(presaleId);
    }

    function test_RevertWhen_PresaleEnded() public {
        uint256 presaleId = _createPresale();

        // 等待预售结束
        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert("Presale ended");
        vm.prank(user1);
        idoPlatform.contribute{value: 1 ether}(presaleId);
    }

    function _createPresale() internal returns (uint256) {
        vm.startPrank(creator);
        uint256 presaleId = idoPlatform.createPresale(
            address(rntToken),
            TOTAL_TOKENS_FOR_SALE,
            TARGET_AMOUNT,
            CAP_AMOUNT,
            MIN_PER_TX,
            MAX_PER_ADDRESS,
            DURATION
        );
        vm.stopPrank();
        return presaleId;
    }
}