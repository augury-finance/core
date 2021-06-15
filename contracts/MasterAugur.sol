// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "./OmenToken.sol";
import "./Operators.sol";
import "./libs/IDividends.sol";
import "./libs/IReferral.sol";
import "./AugurDividendsV1.sol";

// MasterAugur sees all within Augury.
// Eventually, this will be governed by our community.
// Have fun reading it. Hopefully it's bug-free. God bless. :)

contract MasterAugur is Ownable, ReentrancyGuard, Operators {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of OMEN
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accOmenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accOmenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. OMEN to distribute per block.
        uint256 lastRewardBlock;  // Last block number that OMEN distribution occurs.
        uint256 accOmenPerShare;   // Accumulated OMEN per share, times 1e18. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    /* Augury: Omen */
    OmenToken public omen;
    IDividends public dividends;

    /**
        Advisors, Partners and Developers have a vesting schedule on their tokens (see below)
    **/
    address public communityAddress;
    address public devAddress;

    // OMEN tokens created per block.
    uint256 public maxSupply = 777777777 ether; // 777m
    uint256 public omenPerBlock = 17777 finney; // 17.777

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when OMEN mining starts.
    uint256 public startBlock;

    // Omen referrals contract address.
    IReferral public referral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 0;
    // Max referral commission rate: 5%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 500;

    // dividends
    address public dividendsContractAddress;

    /************************
        Addresses 
    *************************/

    // Vesting:
    event SetCommunityAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);

    // Other/Misc:
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    // Referral bonuses:
    event SetReferralAddress(address indexed user, IReferral indexed newAddress);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    // Allows us to change the emission rate (see gitbook)
    event UpdateEmissionRate(address indexed user, uint256 omenPerBlock);
    
    // Watched by our Sentinel Auditing System. This function should only be used if the community requires it. 
    event UpdateMaxSupply(address indexed user, uint256 maxSupply);
    
    constructor(
        OmenToken _omen,
        IERC20 _usdc,
        uint256 _startBlock,
        address _communityAddress,
        address _devAddress
    ) public {
        omen = _omen;
        startBlock = _startBlock;

        communityAddress = _communityAddress;
        devAddress = _devAddress;
        
        dividends = new AugurDividendsV1(_usdc);
        // TODO: Determine which of these we should use...
        dividends.updateOperator(_devAddress, true);
        dividends.updateOperator(msg.sender, true);
        dividends.updateOperator(address(this), true);
        
        dividendsContractAddress = address(dividends);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function _addPool(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP) private {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accOmenPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }
    function add(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP) external onlyOwner nonDuplicated(_lpToken) {
        _addPool(_allocPoint, _lpToken, _depositFeeBP);
    }
    function operatorsAddPool(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP) external onlyOperator {
        _addPool(_allocPoint, _lpToken, _depositFeeBP);
    }

    // Update the given pool's OMEN allocation point and deposit fee. Can only be called by the owner.
    function _setPool(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP) private {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP) external onlyOwner {
        _setPool(_pid, _allocPoint, _depositFeeBP);
    }
    function operatorSetPool(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP) external onlyOperator {
        _setPool(_pid, _allocPoint, _depositFeeBP);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (omen.totalSupply() >= maxSupply) {
            return 0;
        }
        return _to.sub(_from);
    }

    // View function to see pending OMEN on frontend.
    function pendingOmen(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accOmenPerShare = pool.accOmenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 omenReward = multiplier.mul(omenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accOmenPerShare = accOmenPerShare.add(omenReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accOmenPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 omenReward = multiplier.mul(omenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        omen.mint(devAddress, omenReward.div(10));
        omen.mint(address(this), omenReward);
        pool.accOmenPerShare = pool.accOmenPerShare.add(omenReward.mul(1e18).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }
    
    function deposit(uint256 _pid, uint256 _amount, address _referrer) external nonReentrant {
        _deposit(_pid, _amount, msg.sender, _referrer);
    }
    
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        _withdraw(_pid, _amount, msg.sender);
    }
    
    // Restricted deposit function for our own contracts
    function deposit(uint256 _pid, uint256 _amount, address _to, address _referrer) external nonReentrant onlyOperator {
        _deposit(_pid, _amount, _to, _referrer);
    }
    
    // Restricted withdraw function for our own contracts
    function withdraw(uint256 _pid, uint256 _amount, address _to) external nonReentrant onlyOperator {
        _withdraw(_pid, _amount, _to);
    }
    
    // Deposit LP tokens to MasterAugur for OMEN allocation.
    function _deposit(uint256 _pid, uint256 _amount, address _to, address _referrer) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_to];
        updatePool(_pid);
        if (_amount > 0 && address(referral) != address(0) && _referrer != address(0) && _referrer != _to) {
            referral.recordReferral(_to, _referrer);
        }
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accOmenPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                safeOmenTransfer(_to, pending);
                payReferralCommission(_to, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(devAddress, depositFee.mul(4).div(10));
                pool.lpToken.safeTransfer(communityAddress, depositFee.mul(6).div(10));
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }

            dividends.setUserStakedAmount(_pid, _to, user.amount);
        }
        user.rewardDebt = user.amount.mul(pool.accOmenPerShare).div(1e18);
        emit Deposit(_to, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function _withdraw(uint256 _pid, uint256 _amount, address _to) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accOmenPerShare).div(1e18).sub(user.rewardDebt);
        if (pending > 0) {
            safeOmenTransfer(_to, pending);
            payReferralCommission(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(_to, _amount);
            dividends.setUserStakedAmount(_pid, _to,  user.amount);
        }
        user.rewardDebt = user.amount.mul(pool.accOmenPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        dividends.setUserStakedAmount(_pid, msg.sender, 0);
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe omen transfer function, just in case if rounding error causes pool to not have enough OMEN.
    function safeOmenTransfer(address _to, uint256 _amount) internal {
        uint256 omenBalance = omen.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > omenBalance) {
            transferSuccess = omen.transfer(_to, omenBalance);
        } else {
            transferSuccess = omen.transfer(_to, _amount);
        }
        require(transferSuccess, "safeOmenTransfer: Transfer failed");
    }

    function setCommunityAddress(address _communityAddress) external onlyOwner {
        communityAddress = _communityAddress;
        emit SetCommunityAddress(msg.sender, _communityAddress);
    }
    
    function _setDevAddress(address _devAddress) private {
        devAddress = _devAddress;
        emit SetDevAddress(msg.sender, _devAddress);
    }
    function setDevAddress(address _devAddress) external onlyOwner {
        _setDevAddress(_devAddress);
    }
    function operatorSetDevAddress(address _devAddress) external onlyOperator {
        _setDevAddress(_devAddress);
    }
    
    function updateEmissionRate(uint256 _omenPerBlock) external onlyOwner {
        massUpdatePools();
        omenPerBlock = _omenPerBlock;
        emit UpdateEmissionRate(msg.sender, _omenPerBlock);
    }
    
    function updateMaxSupply(uint256 _maxSupply) external onlyOwner {

        maxSupply = _maxSupply;
        emit UpdateMaxSupply(msg.sender, _maxSupply);
    }

    // Update the referral contract address by the owner
    function setReferralAddress(IReferral _referral) external onlyOwner {
        referral = _referral;
        emit SetReferralAddress(msg.sender, _referral);
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) external onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(referral) != address(0) && referralCommissionRate > 0) {
            address referrer = referral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                omen.mint(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Only update before start of farm
    function updateStartBlock(uint256 _startBlock) external onlyOwner {
	    require(startBlock > block.number, "Farm already started");
        startBlock = _startBlock;
    }

    // Dividends
    function changeDividendsContract(IDividends _dividends) external onlyOperator {
        dividends = _dividends;
        dividends.updateOperator(address(_dividends), true);
        dividendsContractAddress = address(_dividends);
    }

    function setDividendsOperator(address _operatorAddress, bool _access) external onlyOperator {
        dividends.updateOperator(_operatorAddress, _access);
    }
}
