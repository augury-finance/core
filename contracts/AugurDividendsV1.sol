// SPDX-License-Identifier: Augury Finance
// COPIED FROM https://github.com/compound-finance/compound-protocol/blob/master/contracts/Governance/GovernorAlpha.sol
// Copyright Augury Finance, 2021. Do not re-use without permission.
// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

pragma solidity ^0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "./libs/IDividends.sol";
import "./Operators.sol";

contract AugurDividendsV1 is Ownable, ReentrancyGuard, Operators, IDividends {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct EpochInfo {
        uint256 lpOmenStaked_d18;
        uint256 nlpOmenStaked_d18;

        uint256 lpUsdcToDistribute_d6;
        uint256 nlpUsdcToDistribute_d6;
    }

    struct UserInfo {
        uint256 lastNlpPositiveStakedTime;
        uint256 lastNlpZeroStakedTime;
        
        uint256 lastLpPositiveStakedTime;
        uint256 lastLpZeroStakedTime;

        uint256 lastEpochClaimed;

        uint256 lpOmenStaked_d18;
        uint256 nlpOmenStaked_d18;

        uint256 lastEpochPended;
        uint256 pendingUsdc_d6;
    }

    uint256 public constant MAX_UINT_256 = uint256(-1);

    IERC20 public dividendToken;

    uint256 public epochDurationSeconds;
    // TODO: rename this to epochStartSecondsOffset
    uint256 public epochDurationSecondsOffset;
    uint256 public lastClosedEpoch;
    uint256 public lastFundedEpoch;
    uint256 public lastFundedAtUtcSeconds;

    uint256 public totalLpOmenStaked_d18;
    uint256 public totalNlpOmenStaked_d18;

    mapping(uint256 => EpochInfo) public epochInfos;
    mapping(address => UserInfo) public userInfos;
    mapping(address => mapping(uint256 => uint256)) public userStakeHistories_nlp;
    mapping(address => mapping(uint256 => uint256)) public userStakeHistories_lp;
    mapping(uint256 => bool) public pidIsNlpPool;
    mapping(uint256 => bool) public pidIsLpPool;
    address[] public stakedUserAddresses;

    event DividendsCollected(address indexed user, uint256 amount);

    constructor(IERC20 _dividendToken) public {
        dividendToken = _dividendToken;

        // 1 week
        epochDurationSeconds = 1 weeks;
        // Fri May 28 2021 09:00:00 GMT-0500 (Central Daylight Time)
        epochDurationSecondsOffset = 1622210400;

        // staging:
        // 1 hours
        // epochDurationSeconds = 1 hours;
        // Tue Jun 15 2021 06:00:00 GMT-0500 (Central Daylight Time)
        // epochDurationSecondsOffset = 1623754800;

        require((now - 2 * epochDurationSeconds) > epochDurationSecondsOffset, "epochDurationSecondsOffset must be at least two epochs in the past.");

        lastClosedEpoch = secondsToEpoch(getNow()) - 1;
        lastFundedEpoch = secondsToEpoch(getNow()) - 1;

        totalLpOmenStaked_d18 = 0;
        totalNlpOmenStaked_d18 = 0;
    }

    function getNow() public virtual view returns (uint256) {
        return now;
    }

    function getUserLastNlpStakedTime(address _user) public view returns (uint256) {
        return userInfos[_user].lastNlpPositiveStakedTime > userInfos[_user].lastNlpZeroStakedTime ? userInfos[_user].lastNlpPositiveStakedTime
            : userInfos[_user].lastNlpZeroStakedTime;
    }

    function getUserLastLpStakedTime(address _user) public view returns (uint256) {
        return userInfos[_user].lastLpPositiveStakedTime > userInfos[_user].lastLpZeroStakedTime ? userInfos[_user].lastLpPositiveStakedTime
            : userInfos[_user].lastLpZeroStakedTime;
    }

    function hasUserStaked(address _user) public view returns (bool) {
        return userInfos[_user].lastLpPositiveStakedTime > 0 ||
            userInfos[_user].lastNlpPositiveStakedTime > 0;
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
        return (_seconds - epochDurationSecondsOffset).div(epochDurationSeconds);
    }

    function currentEpoch() public view returns (uint256) {
        return secondsToEpoch(getNow());
    }

    function calculateOwedDividends_d6(address _address, uint256 _requestedEpoch) public view returns (uint256) {
        // the last epoch that we can safely calculate to is the last funded epoch
        uint256 lastEpoch = _requestedEpoch;
        if(lastFundedEpoch < _requestedEpoch) {
            lastEpoch = lastFundedEpoch;
        }

        // return lastFundedEpoch;
        //  userInfos[_address].lastEpochClaimed;
        if (lastEpoch <= userInfos[_address].lastEpochClaimed) {
            return 0;
        }

        // the user has never staked with us, so they have no rewards...
        // TODO: add unit test
        if(!hasUserStaked(_address)) {
            return 0;
        }

        if(userInfos[_address].lastEpochClaimed == 0) {
            return 0;
        }

        uint256 _userNlpStakedAmount_d18 = 0;
        uint256 _userLpStakedAmount_d18 = 0; 
        
        uint256 _total = 0;
        for (uint256 pastEpoch = userInfos[_address].lastEpochClaimed + 1; pastEpoch <= lastEpoch; pastEpoch++) {
            _userNlpStakedAmount_d18 = userStakeHistories_nlp[_address][pastEpoch] == 0 ? _userNlpStakedAmount_d18
                : userStakeHistories_nlp[_address][pastEpoch];
            _userLpStakedAmount_d18 = userStakeHistories_lp[_address][pastEpoch] == 0 ? _userLpStakedAmount_d18
                : userStakeHistories_lp[_address][pastEpoch];

            if(_userNlpStakedAmount_d18 > 0 && _userNlpStakedAmount_d18 != MAX_UINT_256) {
                _total = _total.add(calculateEpochUsdcAmount_d6(epochInfos[pastEpoch].nlpUsdcToDistribute_d6, epochInfos[pastEpoch].nlpOmenStaked_d18, _userNlpStakedAmount_d18));
            }

            if(_userLpStakedAmount_d18 > 0 && _userNlpStakedAmount_d18 != MAX_UINT_256) {
                _total = _total.add(calculateEpochUsdcAmount_d6(epochInfos[pastEpoch].lpUsdcToDistribute_d6, epochInfos[pastEpoch].lpOmenStaked_d18, _userLpStakedAmount_d18));
            }
        }

        return _total;
    }
    function calculateOwedDividendsFromNow_d6(address _address) external view returns (uint256) {
        return calculateOwedDividends_d6(_address, lastFundedEpoch);
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
        _closeOpenEpochs(currentEpoch());
    }
    
    function fundEpochDistributions(uint256 _epoch, uint256 _nlpUsdc_d6, uint256 _lpUsdc_d6) external onlyOperator nonReentrant {
        closePreviousOpenEpochsFromNow();

        require(_epoch <= lastClosedEpoch, "expected epoch to be in the past.");
        require(_epoch == lastFundedEpoch + 1, "expected epoch to be the next sequential epoch.");

        epochInfos[_epoch].nlpUsdcToDistribute_d6 = _nlpUsdc_d6;
        epochInfos[_epoch].lpUsdcToDistribute_d6 = _lpUsdc_d6;
        lastFundedEpoch = _epoch;
        lastFundedAtUtcSeconds = now;
    }

    // user state
    function _setUserStakedAmount(uint256 _pid, address _userAddress, uint256 _omenTotalStakedAmount_d18) private nonReentrant {
        uint256 _currentEpoch = currentEpoch();
        closePreviousOpenEpochsFromNow();
        
        uint256 _lastStakedAmount = userInfos[_userAddress].nlpOmenStaked_d18;
        if(_pid > 0) {
            _lastStakedAmount = userInfos[_userAddress].lpOmenStaked_d18;
        }

        // when the user first stakes with us, we need to set their lastFundedEpoch to the last epoch.
        if(!hasUserStaked(_userAddress)) {
            userInfos[_userAddress].lastEpochClaimed = lastFundedEpoch;
            stakedUserAddresses.push(_userAddress);
        }

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
            userInfos[_userAddress].nlpOmenStaked_d18 = _omenTotalStakedAmount_d18;
            totalNlpOmenStaked_d18 = totalNlpOmenStaked_d18.add(_incrementTotalBy).sub(_decrementTotalBy);
            userStakeHistories_nlp[_userAddress][_currentEpoch] = _omenTotalStakedAmount_d18;
            if(_omenTotalStakedAmount_d18 == 0) {
                userStakeHistories_nlp[_userAddress][_currentEpoch] = MAX_UINT_256;
            }

            if(_omenTotalStakedAmount_d18 == 0) {
                userInfos[_userAddress].lastNlpZeroStakedTime = getNow();
            } else {
                userInfos[_userAddress].lastNlpPositiveStakedTime = getNow();
            }
        } else {
            // this will only be the pid 1
            userInfos[_userAddress].lpOmenStaked_d18 = _omenTotalStakedAmount_d18;
            totalLpOmenStaked_d18 = totalLpOmenStaked_d18.add(_incrementTotalBy).sub(_decrementTotalBy);
            userStakeHistories_lp[_userAddress][_currentEpoch] = _omenTotalStakedAmount_d18;
            if(_omenTotalStakedAmount_d18 == 0) {
                userStakeHistories_lp[_userAddress][_currentEpoch] = MAX_UINT_256;
            }

            if(_omenTotalStakedAmount_d18 == 0) {
                userInfos[_userAddress].lastLpZeroStakedTime = getNow();
            } else {
                userInfos[_userAddress].lastLpPositiveStakedTime = getNow();
            }
        }
    }
    function setUserStakedAmount(uint256 _pid, address _userAddress, uint256 _omenTotalStakedAmount_d18) external override onlyOwner {
        // only add liquidity if the pool supports dividends
        if(_pid != 0 && _pid != 1) {
            return;
        }

        _setUserStakedAmount(_pid, _userAddress, _omenTotalStakedAmount_d18);
    }

    function _collectDividends(address _userAddress) private nonReentrant returns (uint256) {
        closePreviousOpenEpochsFromNow();

        require(userInfos[_userAddress].lastLpPositiveStakedTime > 0 || userInfos[_userAddress].lastNlpPositiveStakedTime > 0, "you must stake tokens before you are eligible to claim dividends.");
        
        uint256 _totalDividends = calculateOwedDividends_d6(_userAddress, lastFundedEpoch);
        uint lastNlpStakeChangedEpoch = secondsToEpoch(getUserLastNlpStakedTime(_userAddress));
        uint lastLpStakeChangedEpoch = secondsToEpoch(getUserLastLpStakedTime(_userAddress));

        userStakeHistories_nlp[_userAddress][lastFundedEpoch + 1] = userStakeHistories_nlp[_userAddress][lastNlpStakeChangedEpoch];
        userStakeHistories_lp[_userAddress][lastFundedEpoch + 1] = userStakeHistories_lp[_userAddress][lastLpStakeChangedEpoch];
        userInfos[_userAddress].lastEpochClaimed = lastFundedEpoch;

        if (_totalDividends == 0) {
            return 0;
        }

        dividendToken.safeTransfer(address(_userAddress), _totalDividends);

        emit DividendsCollected(_userAddress, _totalDividends);
    }
    function collectDividends() external returns (uint256) {
        return _collectDividends(msg.sender);
    }

    // this method will allow us to completely flush this contract when we migrate to a new dividends contract.
    function distributeUnclaimedDividends(uint256 _from, uint256 _to) external {
        require(_from < _to, "_from must be less than _to.");
        require(_to < stakedUserAddresses.length, "_to must be less than the number of staked users.");

        for(uint256 i = _from; i < _to; i++) {
            _collectDividends(stakedUserAddresses[i]);
        }
    }
}
