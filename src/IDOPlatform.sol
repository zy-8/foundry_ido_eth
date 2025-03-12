// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract IDOPlatform is ReentrancyGuard, Ownable {
  struct Presale {
    IERC20 token;
    address creator; // 预售创建者
    uint256 targetAmount; // ETH target
    uint256 capAmount; // ETH cap
    uint256 minPerTx; // 单笔最小购买量
    uint256 maxPerAddress; // 单地址最大购买量
    uint256 duration; // in seconds
    uint256 startTime;
    //总募集金额
    uint256 totalRaised;
    //预售代币总量
    uint256 totalTokensForSale;
    mapping(address => uint256) contributions;
    mapping(address => bool) claimed;
  }

  mapping(uint256 => Presale) public presales;
  uint256 public presaleCount;
  // 平台手续费
  uint256 public platformFee;
  // 基点: 10000 = 100%
  uint256 public constant BASIS_POINTS = 10000;

  event PresaleCreated(uint256 indexed id, address token, uint256 startTime);
  event PresaleEnded(uint256 indexed id, bool success);
  event Contributed(uint256 indexed id, address indexed user, uint256 amount);

  modifier validPresale(uint256 presaleId) {
    require(presaleId > 0 && presaleId <= presaleCount, "Invalid presale");
    _;
  }

  modifier onlyCreator(uint256 presaleId) {
    require(msg.sender == presales[presaleId].creator, "Not creator");
    _;
  }

  modifier notClaimed(uint256 presaleId) {
    require(!presales[presaleId].claimed[msg.sender], "Already claimed");
    _;
  }

  modifier hasContribution(uint256 presaleId) {
    require(presales[presaleId].contributions[msg.sender] > 0, "No contribution");
    _;
  }

  modifier isActive(uint256 presaleId) {
    require(presales[presaleId].startTime + presales[presaleId].duration > block.timestamp, "Presale ended");
    _;
  }

  modifier notActive(uint256 presaleId) {
    require(presales[presaleId].startTime + presales[presaleId].duration <= block.timestamp, "Presale not ended");
    _;
  }

  constructor(uint256 _platformFee) Ownable(msg.sender) {
    // 平台手续费不能超过10%
    require(_platformFee <= 1000, "Fee too high"); // 1000 = 10%
    platformFee = _platformFee;
  }

  // 创建新预售
  function createPresale(address _token, uint256 _totalTokensForSale, uint256 _targetAmount, uint256 _capAmount, uint256 _minPerTx, uint256 _maxPerAddress, uint256 _duration)
    external
    returns (uint256)
  {
    require(_token != address(0), "Invalid token");
    require(_capAmount >= _targetAmount, "Invalid amounts");
    require(_maxPerAddress >= _minPerTx && _minPerTx > 0, "Invalid limits");

    unchecked {
      presaleCount++;
    }

    Presale storage presale = presales[presaleCount];
    presale.token = IERC20(_token);
    presale.creator = msg.sender;
    presale.targetAmount = _targetAmount;
    presale.capAmount = _capAmount;
    presale.minPerTx = _minPerTx;
    presale.maxPerAddress = _maxPerAddress;
    presale.duration = _duration;
    presale.startTime = block.timestamp;
    presale.totalTokensForSale = _totalTokensForSale;

    emit PresaleCreated(presaleCount, _token, block.timestamp);
    return presaleCount;
  }

  // 参与预售
  function contribute(uint256 presaleId) external payable nonReentrant validPresale(presaleId) isActive(presaleId) {
    Presale storage presale = presales[presaleId];
    require(presale.totalRaised + msg.value <= presale.capAmount, "Cap reached");
    require(msg.value >= presale.minPerTx, "Exceeds tx limit");
    require(presale.contributions[msg.sender] + msg.value <= presale.maxPerAddress, "Exceeds address limit");

    presale.contributions[msg.sender] += msg.value;
    presale.totalRaised += msg.value;

    emit Contributed(presaleId, msg.sender, msg.value);
  }

  // 领取token
  function claim(uint256 presaleId) external notActive(presaleId) nonReentrant validPresale(presaleId) notClaimed(presaleId) hasContribution(presaleId) {
    Presale storage presale = presales[presaleId];
    uint256 contribution = presale.contributions[msg.sender];
    presale.claimed[msg.sender] = true;

    if (presale.totalRaised >= presale.targetAmount) {
      uint256 tokenAmount = (contribution * presale.totalTokensForSale) / presale.totalRaised;
      require(presale.token.transfer(msg.sender, tokenAmount), "Transfer failed");
    } else {
      // 预售失败，退还ETH
      (bool sent,) = msg.sender.call{ value: contribution }("");
      require(sent, "Refund failed");
    }
  }

  // 项目方提现（包含平台手续费）
  function withdrawFunds(uint256 presaleId) external notActive(presaleId) nonReentrant validPresale(presaleId) onlyCreator(presaleId) {
    Presale storage presale = presales[presaleId];
    require(presale.totalRaised >= presale.targetAmount, "Not successful");

    uint256 balance = presale.totalRaised;
    presale.totalRaised = 0;

    // 计算平台手续费 (使用基点计算 更精确) 防止溢出
    uint256 halfBalance = balance / 2;
    uint256 halfFee = (halfBalance * platformFee) / BASIS_POINTS;
    uint256 fee = halfFee * 2;
    uint256 amount = balance - fee;

    // 先发送平台手续费
    (bool sent,) = owner().call{ value: fee }("");
    require(sent, "Platform fee transfer failed");

    // 再发送剩余资金给创建者
    (sent,) = msg.sender.call{ value: amount }("");
    require(sent, "Creator withdrawal failed");
  }

  function getPresaleInfo(uint256 presaleId) external view validPresale(presaleId) returns (uint256 totalRaised, uint256 endTime, bool isSuccessful) {
    Presale storage presale = presales[presaleId];
    return (presale.totalRaised, presale.startTime + presale.duration, presale.totalRaised >= presale.targetAmount);
  }
}
