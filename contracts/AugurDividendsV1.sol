// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "./Operators.sol";

contract AugurDividendsV1 is Ownable, ReentrancyGuard, Operators {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct EpochInfo {
        uint256 lpOmenStaked_d18;
        uint256 nlpOmenStaked_d18;

        uint256 lpUsdcToDistribute_d6;
        uint256 nlpUsdcToDistribute_d6;

        bool usdcFunded;
    }

    struct UserInfo {
        uint256 lastZeroStakedTime;
        uint256 lastPositiveStakedTime;

        uint256 lastEpochClaimed;
        uint256 lastEpochPended;

        uint256 pendingUsdc_d6;

        uint256 lpOmenStaked_d18;
        uint256 nlpOmenStaked_d18;
    }

    IERC20 public dividendToken;

    uint256 public epochDurationSeconds;
    uint256 public lastClosedEpoch;
    uint256 public lastFundedEpoch;

    uint256 public totalLpOmenStaked_d18;
    uint256 public totalNlpOmenStaked_d18;

    mapping(uint256 => EpochInfo) public epochInfos;
    mapping(address => UserInfo) public userInfos;

    event DividendsCollected(address indexed user, uint256 amount);

    constructor(IERC20 _dividendToken) public {
        dividendToken = _dividendToken;

        // 1 week
        epochDurationSeconds = 1 weeks;
        lastClosedEpoch = secondsToEpoch(getNow()) - 1;
        lastFundedEpoch = secondsToEpoch(getNow()) - 1;

        totalLpOmenStaked_d18 = 0;
        totalNlpOmenStaked_d18 = 0;
    }

    function getNow() public virtual view returns (uint256) {
        return now;
    }

    // Calculations...
    function calculateEpochUsdcAmount_d6(uint256 _epochUsdcTotal_d6, uint256 _epochTotalStakedOmen_d18, uint256 _userStakedOmen_d18) public pure returns (uint256) {
        if(_userStakedOmen_d18 == 0 || _epochTotalStakedOmen_d18 == 0) {
            return 0;
        }

        uint256 _numerator= _epochUsdcTotal_d6.mul(_userStakedOmen_d18).mul(1e18);
        uint256 _denominator = _epochTotalStakedOmen_d18;

        return _numerator.div(_denominator).div(1e18);
    }
    
    function secondsToEpoch(uint256 _seconds) public view returns (uint256) {
        return _seconds.div(epochDurationSeconds);
    }

    function calculateOwedDividends_d6(address _address, uint256 _requestedEpoch) public view returns (uint256) {
        // the last epoch that we can safely calculate to is the last funded epoch
        uint256 lastEpoch = _requestedEpoch;
        if(lastFundedEpoch < _requestedEpoch) {
            lastEpoch = lastFundedEpoch;
        }

        if (lastEpoch <= userInfos[_address].lastEpochClaimed) {
            return 0;
        }

        // epoch difference is the difference between the lastEpoch
        // and the max of
        // -> lastEpochClaimed
        // -> lastEpochPended
        // -> lastZeroEpoch
        uint256 maxAffectableEpoch = userInfos[_address].lastEpochClaimed;
        if (maxAffectableEpoch < userInfos[_address].lastEpochPended) {
            maxAffectableEpoch = userInfos[_address].lastEpochPended;
        }
        uint256 _lastZeroStakedEpoch = secondsToEpoch(userInfos[_address].lastZeroStakedTime);
        if(maxAffectableEpoch < _lastZeroStakedEpoch) {
            maxAffectableEpoch = _lastZeroStakedEpoch;
        }

        uint256 _userNlpStakedAmount_d18 = userInfos[_address].nlpOmenStaked_d18;
        uint256 _userLpStakedAmount_d18 = userInfos[_address].lpOmenStaked_d18;

        uint256 _total = userInfos[_address].pendingUsdc_d6;
        for (uint256 pastEpoch = maxAffectableEpoch + 1; pastEpoch <= lastEpoch; pastEpoch++) {
            if(_userNlpStakedAmount_d18 > 0) {
                _total = _total.add(calculateEpochUsdcAmount_d6(epochInfos[pastEpoch].nlpUsdcToDistribute_d6, epochInfos[pastEpoch].nlpOmenStaked_d18, _userNlpStakedAmount_d18));
            }

            if(_userLpStakedAmount_d18 > 0) {
                _total = _total.add(calculateEpochUsdcAmount_d6(epochInfos[pastEpoch].lpUsdcToDistribute_d6, epochInfos[pastEpoch].lpOmenStaked_d18, _userLpStakedAmount_d18));
            }
        }

        return _total;
    }
    function calculateOwedDividendsFromNow_d6(address _address) public view returns (uint256) {
        return calculateOwedDividends_d6(_address, lastClosedEpoch);
    }

    // contract state
    function _closeOpenEpochs(uint256 _epoch) private {
        while(lastClosedEpoch + 1 < _epoch) {
            lastClosedEpoch = lastClosedEpoch + 1;

            epochInfos[lastClosedEpoch].lpOmenStaked_d18 = totalLpOmenStaked_d18;
            epochInfos[lastClosedEpoch].nlpOmenStaked_d18 = totalNlpOmenStaked_d18;
        }
    }
    function closePreviousOpenEpochsFromNow() public {
        // this can be public because it is idempotent
        uint256 _currentEpoch = secondsToEpoch(getNow());
        _closeOpenEpochs(_currentEpoch);
    }
    
    function fundEpochDistributions(uint256 _epoch, uint256 _nlpUsdc_d6, uint256 _lpUsdc_d6) external onlyOperator nonReentrant {
        closePreviousOpenEpochsFromNow();

        require(_epoch <= lastClosedEpoch, "expected epoch to be in the past.");
        require(_epoch == lastFundedEpoch + 1, "expected epoch to be the next sequential epoch.");

        epochInfos[_epoch].nlpUsdcToDistribute_d6 = _nlpUsdc_d6;
        epochInfos[_epoch].lpUsdcToDistribute_d6 = _lpUsdc_d6;
        lastFundedEpoch = _epoch;
    }

    // user state
    function _setUserStakedAmount(uint256 _pid, address _userAddress, uint256 _omenTotalStakedAmount_d18) private nonReentrant {
        closePreviousOpenEpochsFromNow();
        
        uint256 _lastStakedAmount = userInfos[_userAddress].nlpOmenStaked_d18;
        if(_pid > 0) {
            _lastStakedAmount = userInfos[_userAddress].lpOmenStaked_d18;
        }

        // when the user changes their stake in a current epoch
        // we update their pending stake for all previous epochs
        userInfos[_userAddress].pendingUsdc_d6 = calculateOwedDividends_d6(_userAddress, lastClosedEpoch);
        userInfos[_userAddress].lastEpochPended = lastClosedEpoch;

        // when the user removes stake
        uint256 _decrementTotalBy = 0;
        if(_lastStakedAmount > _omenTotalStakedAmount_d18) {
            _decrementTotalBy = _lastStakedAmount.sub(_omenTotalStakedAmount_d18);
        }

        // when the user adds stake
        uint256 _incrementTotalBy = 0;
        if (_lastStakedAmount < _omenTotalStakedAmount_d18) {
            _incrementTotalBy = _omenTotalStakedAmount_d18.sub(_lastStakedAmount);
        }

        if(_pid == 0) {
            totalNlpOmenStaked_d18 = totalNlpOmenStaked_d18.add(_incrementTotalBy).sub(_decrementTotalBy);
            userInfos[_userAddress].nlpOmenStaked_d18 = _omenTotalStakedAmount_d18;
        } else {
            totalLpOmenStaked_d18 = totalLpOmenStaked_d18.add(_incrementTotalBy).sub(_decrementTotalBy);
            userInfos[_userAddress].lpOmenStaked_d18 = _omenTotalStakedAmount_d18;
        }

        if(userInfos[_userAddress].nlpOmenStaked_d18 == 0 && userInfos[_userAddress].lpOmenStaked_d18 == 0) {
            userInfos[_userAddress].lastZeroStakedTime = getNow();
        } else {
            userInfos[_userAddress].lastPositiveStakedTime = getNow();
        }
    }
    function setUserStakedAmount(uint256 _pid, address _userAddress, uint256 _omenTotalStakedAmount_d18) external onlyOwner {
        _setUserStakedAmount(_pid, _userAddress, _omenTotalStakedAmount_d18);
    }

    function _collectDividends(address _userAddress) private nonReentrant returns (uint256) {
        closePreviousOpenEpochsFromNow();

        require(lastClosedEpoch == lastFundedEpoch, "USDC must be funded before you may collect dividends");

        uint256 _totalDividends = calculateOwedDividends_d6(_userAddress, lastClosedEpoch);
        userInfos[_userAddress].pendingUsdc_d6 = 0;
        userInfos[_userAddress].lastEpochClaimed = lastClosedEpoch;

        if (_totalDividends == 0) {
            return 0;
        }

        dividendToken.safeTransfer(address(_userAddress), _totalDividends);

        emit DividendsCollected(_userAddress, _totalDividends);
    }
    function collectUserDividends(address _userAddress) external onlyOwner returns (uint256) {
        return _collectDividends(_userAddress);
    }
    function collectDividends() external returns (uint256) {
        return _collectDividends(msg.sender);
    }
}
