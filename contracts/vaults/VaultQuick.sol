// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*
  ___                      _   _
 | _ )_  _ _ _  _ _ _  _  | | | |
 | _ \ || | ' \| ' \ || | |_| |_|
 |___/\_,_|_||_|_||_\_, | (_) (_)
                    |__/

*
* MIT License
* ===========
*
* Copyright (c) 2020 BunnyFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import {PoolConstant} from "../library/PoolConstant.sol";
import "../interfaces/IPancakePair.sol";
import "../interfaces/IPancakeFactory.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IBunnyMinter.sol";
import "../interfaces/IQuickStakingRewards.sol";
import "../interfaces/IZap.sol";

import "./VaultController.sol";

contract VaultQuickFlipToFlip is VaultController, IStrategy {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    /* ========== CONSTANTS ============= */

    IBEP20 private constant QUICK = IBEP20(0x831753DD7087CaC61aB5644b308642cc1c33Dc13);
    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.FlipToFlip;
    IZap public constant zap = IZap(0x663462430834E220851a3E981D0E1199501b84F6);
    uint256 public constant override pid = 9999;

    uint256 private constant DUST = 1000;

    /* ========== STATE VARIABLES ========== */

    address private _token0; // unused
    address private _token1; // unused

    uint256 public totalShares;
    mapping(address => uint256) private _shares;
    mapping(address => uint256) private _principal;
    mapping(address => uint256) private _depositedAt;

    IQuickStakingRewards private qVault;

    /* ========== INITIALIZER ========== */

    function initialize(address _token, address _qVault) external initializer {
        __VaultController_init(IBEP20(_token));

        qVault = IQuickStakingRewards(_qVault);
        _stakingToken.safeApprove(address(_qVault), uint256(-1));
        QUICK.safeApprove(address(zap), uint256(-1));
    }

    /* ========== VIEW FUNCTIONS ========== */

    function totalSupply() external view override returns (uint256) {
        return totalShares;
    }

    function balance() public view override returns (uint256 amount) {
        amount = qVault.balanceOf(address(this));
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (totalShares == 0) return 0;
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function withdrawableBalanceOf(address account) public view override returns (uint256) {
        return balanceOf(account);
    }

    function sharesOf(address account) public view override returns (uint256) {
        return _shares[account];
    }

    function principalOf(address account) public view override returns (uint256) {
        return _principal[account];
    }

    function earned(address account) public view override returns (uint256) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function depositedAt(address account) external view override returns (uint256) {
        return _depositedAt[account];
    }

    function rewardsToken() external view override returns (address) {
        return address(_stakingToken);
    }

    function priceShare() external view override returns (uint256) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint256 _amount) public override {
        _depositTo(_amount, msg.sender);
    }

    function depositAll() external override {
        deposit(_stakingToken.balanceOf(msg.sender));
    }

    function withdrawAll() external override {
        uint256 amount = balanceOf(msg.sender);
        uint256 principal = principalOf(msg.sender);
        uint256 depositTimestamp = _depositedAt[msg.sender];

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        amount = _withdrawTokenWithCorrection(amount);
        uint256 profit = amount > principal ? amount.sub(principal) : 0;

        uint256 withdrawalFee = canMint() ? _minter.withdrawalFee(principal, depositTimestamp) : 0;
        uint256 performanceFee = canMint() ? _minter.performanceFee(profit) : 0;
        if (canMint()) {
            if (withdrawalFee.add(performanceFee) > DUST) {
                _minter.mintForV2(address(_stakingToken), withdrawalFee, performanceFee, msg.sender, depositTimestamp);

                if (performanceFee > 0) {
                    emit ProfitPaid(msg.sender, profit, performanceFee);
                }
                amount = amount.sub(withdrawalFee).sub(performanceFee);
            }
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function harvest() external override onlyKeeper {
        uint256 quickHarvested = _harvest();

        uint256 before = _stakingToken.balanceOf(address(this));
        zap.zapInToken(address(QUICK), quickHarvested, address(_stakingToken));
        uint256 harvested = _stakingToken.balanceOf(address(this)).sub(before);

        qVault.stake(harvested);
        emit Harvested(harvested);
    }

    function withdraw(uint256) external override onlyWhitelisted {
        revert("N/A");
    }

    // @dev underlying only + withdrawal fee + no perf fee
    function withdrawUnderlying(uint256 _amount) external {
        uint256 amount = Math.min(_amount, _principal[msg.sender]);
        uint256 shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _principal[msg.sender] = _principal[msg.sender].sub(amount);

        amount = _withdrawTokenWithCorrection(amount);
        uint256 depositTimestamp = _depositedAt[msg.sender];
        uint256 withdrawalFee = canMint() ? _minter.withdrawalFee(amount, depositTimestamp) : 0;
        if (canMint()) {
            if (withdrawalFee > DUST) {
                _minter.mintForV2(address(_stakingToken), withdrawalFee, 0, msg.sender, depositTimestamp);
                amount = amount.sub(withdrawalFee);
            }
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    // @dev profits only (underlying + bunny) + no withdraw fee + perf fee
    function getReward() external override {
        uint256 amount = earned(msg.sender);
        uint256 shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _cleanupIfDustShares();

        amount = _withdrawTokenWithCorrection(amount);
        uint256 depositTimestamp = _depositedAt[msg.sender];
        uint256 performanceFee = canMint() ? _minter.performanceFee(amount) : 0;
        if (canMint()) {
            if (performanceFee > DUST) {
                _minter.mintForV2(address(_stakingToken), 0, performanceFee, msg.sender, depositTimestamp);
                amount = amount.sub(performanceFee);
            }
        }
        _stakingToken.safeTransfer(msg.sender, amount);
        emit ProfitPaid(msg.sender, amount, performanceFee);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _depositTo(uint256 _amount, address _to) private notPaused {
        uint256 _pool = balance();
        uint256 _before = _stakingToken.balanceOf(address(this));
        _stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _after = _stakingToken.balanceOf(address(this));
        _amount = _after.sub(_before); // Additional check for deflationary tokens
        uint256 shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        _principal[_to] = _principal[_to].add(_amount);
        _depositedAt[_to] = block.timestamp;

        qVault.stake(_amount);
        emit Deposited(_to, _amount);
    }

    function _withdrawTokenWithCorrection(uint256 amount) private returns (uint256) {
        uint256 before = _stakingToken.balanceOf(address(this));
        qVault.withdraw(amount);
        return _stakingToken.balanceOf(address(this)).sub(before);
    }

    function _harvest() private returns (uint256) {
        uint256 before = QUICK.balanceOf(address(this));
        qVault.getReward();
        return QUICK.balanceOf(address(this)).sub(before);
    }

    function _cleanupIfDustShares() private {
        uint256 shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */

    // @dev stakingToken must not remain balance in this contract. So dev should salvage staking token transferred by mistake.
    function recoverToken(address token, uint256 amount) external override onlyOwner {
        IBEP20(token).safeTransfer(owner(), amount);
        emit Recovered(token, amount);
    }
}
