// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

contract StrategySelf is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    
    address public vaultChefAddress;
    address public govAddress;
    address public wantAddress;

    /**
     * Advisors, Partners and Developers have a vesting schedule on their tokens (see below)
     */
    address public communityAddress;
    address public devAddress;

    uint256 public sharesTotal = 0;

    uint256 public entranceFeeFactor = 9600; // 9600 = 4%
    uint256 public constant entranceFeeFactorMax = 10000;
    uint256 public constant entranceFeeFactorLL = 9000; // 10% max

    uint256 public withdrawFeeFactor = 10000; // 0% withdraw fee
    uint256 public constant withdrawFeeFactorMax = 10000;
    uint256 public constant withdrawFeeFactorLL = 9900; // 1% max

    constructor(
        address _vaultChefAddress,
        address _wantAddress,
        address _communityAddress,
        address _devAddress,
        uint256 _entranceFeeFactor,
        uint256 _withdrawFeeFactor
    ) public {
        govAddress = msg.sender;
        
        vaultChefAddress = _vaultChefAddress;
        wantAddress = _wantAddress;

        communityAddress = _communityAddress;
        devAddress = _devAddress;
        
        entranceFeeFactor = _entranceFeeFactor;
        withdrawFeeFactor = _withdrawFeeFactor;

        transferOwnership(vaultChefAddress);
    }
    
    event SetSettings(
        uint256 _entranceFeeFactor,
        uint256 _withdrawFeeFactor,
        address _communityAddress,
        address _devAddress
    );
    
    modifier onlyGov() {
        require(msg.sender == govAddress, "!gov");
        _;
    }
    
    function deposit(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant whenNotPaused returns (uint256) {
        IERC20(wantAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );
        
        // Entrance fee
        uint256 entranceFee = _wantAmt
            .mul(entranceFeeFactorMax.sub(entranceFeeFactor))
            .div(entranceFeeFactorMax);
        IERC20(wantAddress).safeTransfer(devAddress, entranceFee.mul(6).div(10));
        IERC20(wantAddress).safeTransfer(communityAddress, entranceFee.mul(4).div(10));

        return _wantAmt.sub(entranceFee);
    }

    function withdraw(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt is 0");
        
        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));

        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (_wantAmt > wantLockedTotal()) {
            _wantAmt = wantLockedTotal();
        }

        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal());
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);
        
        // Withdraw fee
        uint256 withdrawFee = _wantAmt
            .mul(withdrawFeeFactorMax.sub(withdrawFeeFactor))
            .div(withdrawFeeFactorMax);
        IERC20(wantAddress).safeTransfer(devAddress, withdrawFee.mul(6).div(10));
        IERC20(wantAddress).safeTransfer(communityAddress, withdrawFee.mul(4).div(10));
        
        _wantAmt = _wantAmt.sub(withdrawFee);

        IERC20(wantAddress).safeTransfer(vaultChefAddress, _wantAmt);

        return sharesRemoved;
    }

    // Emergency!!
    function pause() external onlyGov {
        _pause();
    }

    // False alarm
    function unpause() external onlyGov {
        _unpause();
    }
    
    function wantLockedTotal() public view returns (uint256) {
        return IERC20(wantAddress).balanceOf(address(this));
    }
    
    function setSettings(
        uint256 _entranceFeeFactor,
        uint256 _withdrawFeeFactor,
        address _communityAddress,
        address _devAddress
    ) external onlyGov {
        require(_entranceFeeFactor >= entranceFeeFactorLL, "_entranceFeeFactor too low");
        require(_entranceFeeFactor <= entranceFeeFactorMax, "_entranceFeeFactor too high");
        require(_withdrawFeeFactor >= withdrawFeeFactorLL, "_withdrawFeeFactor too low");
        require(_withdrawFeeFactor <= withdrawFeeFactorMax, "_withdrawFeeFactor too high");
        entranceFeeFactor = _entranceFeeFactor;
        withdrawFeeFactor = _withdrawFeeFactor;
        communityAddress = _communityAddress;
        devAddress = _devAddress;

        emit SetSettings(
            _entranceFeeFactor,
            _withdrawFeeFactor,
            _communityAddress,
            _devAddress
        );
    }

    function setGov(address _govAddress) external onlyGov {
        govAddress = _govAddress;
    }
}