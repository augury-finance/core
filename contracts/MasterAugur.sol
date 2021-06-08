// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/EnumerableSet.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "./libs/IStrategy.sol";
import "./libs/IReferral.sol";
import "./OmenToken.sol";
import "./Operators.sol";

contract MasterAugur is Ownable, ReentrancyGuard, Operators {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 shares; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.

        // We do some fancy math here. Basically, any point in time, the amount of AUTO
        // entitled to a user but is pending to be distributed is:
        //
        //   amount = user.shares / sharesTotal * wantLockedTotal
        //   pending reward = (amount * pool.accOMENPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws want tokens to a pool. Here's what happens:
        //   1. The pool's `accAUTOPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    struct PoolInfo {
        IERC20 want; // Address of the want token.
        uint256 allocPoint; // How many allocation points assigned to this pool. OMEN to distribute per block.
        uint256 lastRewardBlock; // Last block number that OMEN distribution occurs.
        uint256 accOmenPerShare; // Accumulated OMEN per share, times 1e18. See below.
        address strat; // Strategy address that will auto compound want tokens
    }

    /* Augury: Omen */
    OmenToken public omen;

    /**
     * Community & Developer
     */
    address public communityAddress;
    address public devAddress;

    // OMEN tokens created per block.
    uint256 public constant maxSupply = 77777777 ether; // 77.77M
    uint256 public omenPerBlock = 1770 finney; // 1.77

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    mapping(address => bool) private strats;

    uint256 public startBlock = 77777777; 
    uint256 public totalAllocPoint = 0; // Total allocation points. Must be the sum of all allocation points in all pools.
    
    // Omen referrals contract address.
    IReferral public referral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate;
    // Max referral commission rate: 5%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 500;
    
    // Vesting:
    event SetCommunityAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);

    event AddPool(address indexed strat);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    // Referral bonuses:
    event SetReferralAddress(address indexed user, IReferral indexed newAddress);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);
    
    // Allows us to change the emission rate (see gitbook)
    event UpdateEmissionRate(address indexed user, uint256 omenPerBlock);
    
    constructor(
        OmenToken _omen,
        uint256 _startBlock,
        address _communityAddress,
        address _devAddress,
        IReferral _referralAddress,
        uint16 _referralCommissionRate
    ) public {
        omen = _omen;
        startBlock = _startBlock;

        communityAddress = _communityAddress;
        devAddress = _devAddress;
        referral = _referralAddress;
        referralCommissionRate = _referralCommissionRate;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * @dev Add a new want to the pool. Can only be called by the owner.
     */
    function addPool(uint256 _allocPoint, address _strat) external onlyOwner nonReentrant {
        require(!strats[_strat], "Existing strategy");
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        poolInfo.push(
            PoolInfo({
                want: IERC20(IStrategy(_strat).wantAddress()),
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accOmenPerShare: 0,
                strat: _strat
            })
        );
        strats[_strat] = true;
        resetSingleAllowance(poolInfo.length.sub(1));
        emit AddPool(_strat);
    }

    // Update the given pool's OMEN allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint
    ) public onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }
    
    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
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
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        if (block.number > pool.lastRewardBlock && sharesTotal != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 omenReward = multiplier.mul(omenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accOmenPerShare = accOmenPerShare.add(omenReward.mul(1e18).div(sharesTotal));
        }
        return user.shares.mul(accOmenPerShare).div(1e18).sub(user.rewardDebt);
    }


    // View function to see staked Want tokens on frontend.
    function stakedWantTokens(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        uint256 wantLockedTotal = IStrategy(poolInfo[_pid].strat).wantLockedTotal();
        if (sharesTotal == 0) {
            return 0;
        }
        return user.shares.mul(wantLockedTotal).div(sharesTotal);
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
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (sharesTotal == 0 || pool.allocPoint == 0 || multiplier == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 omenReward = multiplier.mul(omenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        omen.mint(devAddress, omenReward.div(10));
        omen.mint(address(this), omenReward);
        pool.accOmenPerShare = pool.accOmenPerShare.add(omenReward.mul(1e18).div(sharesTotal));
        pool.lastRewardBlock = block.number;
    }


    // Want tokens moved from user -> this -> Strat (compounding)
    function deposit(uint256 _pid, uint256 _wantAmt) external nonReentrant {
        _deposit(_pid, _wantAmt, msg.sender);
    }

    // For unique contract calls
    function deposit(uint256 _pid, uint256 _wantAmt, address _to) external nonReentrant onlyOperator {
        _deposit(_pid, _wantAmt, _to);
    }
    
    function _deposit(uint256 _pid, uint256 _wantAmt, address _to) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_to];

        // Withdraw pending Omen
        if (user.shares > 0) {
            uint256 pending = user.shares.mul(pool.accOmenPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                safeOmenTransfer(_to, pending);
            }
        }
        if (_wantAmt > 0) {
            pool.want.safeTransferFrom(msg.sender, address(this), _wantAmt);

            uint256 sharesAdded = IStrategy(poolInfo[_pid].strat).deposit(_to, _wantAmt);
            user.shares = user.shares.add(sharesAdded);
        }
        user.rewardDebt = user.shares.mul(pool.accOmenPerShare).div(1e18);
        emit Deposit(_to, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _wantAmt) external nonReentrant {
        _withdraw(_pid, _wantAmt, msg.sender);
    }

    // For unique contract calls
    function withdraw(uint256 _pid, uint256 _wantAmt, address _to) external nonReentrant onlyOperator {
        _withdraw(_pid, _wantAmt, _to);
    }

    function _withdraw(uint256 _pid, uint256 _wantAmt, address _to) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 wantLockedTotal = IStrategy(poolInfo[_pid].strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(poolInfo[_pid].strat).sharesTotal();

        require(user.shares > 0, "user.shares is 0");
        require(sharesTotal > 0, "sharesTotal is 0");
        
        // Withdraw pending Omen
        uint256 pending = user.shares.mul(pool.accOmenPerShare).div(1e18).sub(user.rewardDebt);
        if (pending > 0) {
            safeOmenTransfer(_to, pending);
        }

        // Withdraw want tokens
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 sharesRemoved = IStrategy(poolInfo[_pid].strat).withdraw(msg.sender, _wantAmt);

            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }

            uint256 wantBal = IERC20(pool.want).balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            pool.want.safeTransfer(_to, _wantAmt);
        }
        user.rewardDebt = user.shares.mul(pool.accOmenPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    // Withdraw everything from pool for yourself
    function withdrawAll(uint256 _pid) external {
        _withdraw(_pid, uint256(-1), msg.sender);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 wantLockedTotal = IStrategy(poolInfo[_pid].strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(poolInfo[_pid].strat).sharesTotal();
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);

        IStrategy(poolInfo[_pid].strat).withdraw(msg.sender, amount);

        pool.want.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
        user.shares = 0;
        user.rewardDebt = 0;
    }
    
    function safeOmenTransfer(address _to, uint256 _amt) internal {
        uint256 bal = omen.balanceOf(address(this));
        if (_amt > bal) {
            omen.transfer(_to, bal);
        } else {
            omen.transfer(_to, _amt);
        }
    }

    function resetAllowances() external onlyOwner {
        for (uint256 i=0; i<poolInfo.length; i++) {
            PoolInfo storage pool = poolInfo[i];
            pool.want.safeApprove(pool.strat, uint256(0));
            pool.want.safeIncreaseAllowance(pool.strat, uint256(-1));
        }
    }

    function resetSingleAllowance(uint256 _pid) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        pool.want.safeApprove(pool.strat, uint256(0));
        pool.want.safeIncreaseAllowance(pool.strat, uint256(-1));
    }

    function setCommunityAddress(address _communityAddress) external onlyOwner {
        communityAddress = _communityAddress;
        emit SetCommunityAddress(msg.sender, _communityAddress);
    }

    function setDevAddress(address _devAddress) external onlyOwner {
        devAddress = _devAddress;
        emit SetDevAddress(msg.sender, _devAddress);
    }
    
    function updateEmissionRate(uint256 _omenPerBlock) external onlyOwner {
        massUpdatePools();
        omenPerBlock = _omenPerBlock;
        emit UpdateEmissionRate(msg.sender, _omenPerBlock);
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

}