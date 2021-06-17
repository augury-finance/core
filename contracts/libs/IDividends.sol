// SPDX-License-Identifier: Augury Finance
pragma solidity ^0.6.12;

interface IDividends {
    function calculateOwedDividends_d6(address _address, uint256 _requestedEpoch) public view returns (uint256);
    function calculateOwedDividendsFromNow_d6(address _address) external view returns (uint256);
    function _collectDividends(address _userAddress) private nonReentrant returns (uint256);
}