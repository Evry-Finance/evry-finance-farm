//contracts/EVRYDistributor.sol
// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract EVRYDistributor is Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  IERC20 public evry;
  uint256 public cap;
  uint256 public released;
  
  constructor(
    IERC20 _evry,
    uint256 _cap
  ) {
    evry = _evry;
    cap = _cap;
  }

  function release(uint256 amount) external nonReentrant onlyOwner {

    require(released.add(amount) <= cap, "release: cap exceed");
    require(amount <= evry.balanceOf(address(this)), "release: not enough evry");
    
    released = released.add(amount);
    evry.safeTransfer(msg.sender, amount);
  }
  
}
