// SPDX-License-Identifier: MIT

// Referral Interface

pragma solidity ^0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";

import "./IOperable.sol";

interface IDividends is IOperable {
  function setUserStakedAmount(uint256 _pid, address _userAddress, uint256 _omenTotalStakedAmount_d18) external;
}
