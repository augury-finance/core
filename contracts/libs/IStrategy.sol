// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

// For interacting with our own strategy
interface IStrategy {
    // Want address
    function wantAddress() external view returns (address);
    
    // Total want tokens managed by strategy
    function wantLockedTotal() external view returns (uint256);

    // Sum of all shares of users to wantLockedTotal
    function sharesTotal() external view returns (uint256);

    // Main want token compounding function
    function earn() external;

    // Transfer want tokens autoFarm -> strategy
    function deposit(address _userAddress, uint256 _wantAmt) external returns (uint256);

    // Transfer want tokens strategy -> vaultChef
    function withdraw(address _userAddress, uint256 _wantAmt) external returns (uint256);
}