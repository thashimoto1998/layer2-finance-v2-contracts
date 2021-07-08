// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/aave/ILendingPool.sol";
import "../interfaces/aave/IAToken.sol";
import "../interfaces/aave/IAaveIncentivesController.sol";
import "../interfaces/aave/IStakedAave.sol";
import "../interfaces/uniswap/IUniswapV2.sol";

/**
 * Deposits ERC20 token into Aave Lending Pool and issues stAaveLendingToken(e.g. stAaveLendingDAI) in L2. Holds aToken (Aave interest-bearing tokens).
 */
contract StrategyAaveLendingPool is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of Aave Lending Pool
    address public lendingPool;

    // The address of supplying token (e.g. DAI, USDT)
    address public supplyToken;

    // The address of Aave interest-bearing token (e.g. aDAI, aUSDT)
    address public aToken;

    address public controller;

    // The address of Aave Incentives Controller
    address public incentivesController;

    // The address of Aave StakedAave contract
    address public stakedAave;

    // The address of AAVE token
    address public aave;

    address public uniswap;
    // The address of WETH token
    address public weth;

    uint256 internal constant MAX_INT = 2**256 - 1;
    uint256 internal constant PRICE_PRECISION = 1e18;

    uint256 public shares;

    constructor(
        address _lendingPool,
        address _supplyToken,
        address _aToken,
        address _controller,
        address _incentivesController,
        address _stakedAave,
        address _aave,
        address _uniswap,
        address _weth
    ) {
        lendingPool = _lendingPool;
        supplyToken = _supplyToken;
        aToken = _aToken;
        controller = _controller;
        incentivesController = _incentivesController;
        stakedAave = _stakedAave;
        aave = _aave;
        uniswap = _uniswap;
        weth = _weth;
    }

    /**
     * @dev Require that the caller must be an EOA account to avoid flash loans.
     */
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Not EOA");
        _;
    }

    function getAssetAddress() external view override returns (address) {
        return supplyToken;
    }

    function aggregateOrders(
        uint256 _buyAmount,
        uint256 _sellShares,
        uint256 _minSharesFromBuy,
        uint256 _minAmountFromSell
    ) external override returns (uint256, uint256) {
        require(msg.sender == controller, "Not controller");
        require(shares >= _sellShares, "not enough shares to sell");

        uint256 sharesFromBuy;
        uint256 amountFromSell;
        uint256 assetAmount = IAToken(aToken).balanceOf(address(this));
        if (assetAmount != 0 && shares != 0) {
            amountFromSell = (_sellShares * assetAmount) / shares;
        }
        require(amountFromSell >= _minAmountFromSell, "failed min amount from sell");

        if (_buyAmount == amountFromSell) {
            sharesFromBuy = (_buyAmount * shares) / assetAmount;
            return (sharesFromBuy, amountFromSell);
        }

        bool toBuy = _buyAmount > amountFromSell;
        if (toBuy) {
            _buy(_buyAmount - amountFromSell);
        } else {
            _sell(amountFromSell - _buyAmount);
        }

        uint256 newAssetAmount = IAToken(aToken).balanceOf(address(this));
        if (assetAmount == 0) {
            sharesFromBuy = newAssetAmount; //init buy
        } else {
            sharesFromBuy = (shares * newAssetAmount) / assetAmount + _sellShares - shares;
        }
        require(sharesFromBuy >= _minSharesFromBuy, "failed min shares from buy");

        if (_buyAmount > 0) {
            emit Buy(_buyAmount, sharesFromBuy);
        }
        if (_sellShares > 0) {
            emit Sell(_sellShares, amountFromSell);
        }

        shares = shares + sharesFromBuy - _sellShares;

        return (sharesFromBuy, amountFromSell);
    }

    function syncPrice() external view override returns (uint256) {
        uint256 assetAmount = IAToken(aToken).balanceOf(address(this));
        if (shares == 0) {
            if (assetAmount == 0) {
                return PRICE_PRECISION;
            }
            return MAX_INT;
        }
        return (assetAmount * PRICE_PRECISION) / shares;
    }

    function harvest() external override onlyEOA {
        // 1. Claims the liquidity incentives
        address[] memory assets = new address[](1);
        assets[0] = aToken;
        uint256 rewardsBalance =
            IAaveIncentivesController(incentivesController).getRewardsBalance(assets, address(this));
        if (rewardsBalance > 0) {
            IAaveIncentivesController(incentivesController).claimRewards(assets, rewardsBalance, address(this));
        }

        // 2. Activates the cooldown period if not already activated
        uint256 stakedAaveBalance = IERC20(stakedAave).balanceOf(address(this));
        if (stakedAaveBalance > 0 && IStakedAave(stakedAave).stakersCooldowns(address(this)) == 0) {
            IStakedAave(stakedAave).cooldown();
        }

        // 3. Claims the AAVE staking rewards
        uint256 stakingRewards = IStakedAave(stakedAave).getTotalRewardsBalance(address(this));
        if (stakingRewards > 0) {
            IStakedAave(stakedAave).claimRewards(address(this), stakingRewards);
        }

        // 4. Redeems staked AAVE if possible
        uint256 cooldownStartTimestamp = IStakedAave(stakedAave).stakersCooldowns(address(this));
        if (
            stakedAaveBalance > 0 &&
            block.timestamp > cooldownStartTimestamp + IStakedAave(stakedAave).COOLDOWN_SECONDS() &&
            block.timestamp <=
            cooldownStartTimestamp + IStakedAave(stakedAave).COOLDOWN_SECONDS() + IStakedAave(stakedAave).UNSTAKE_WINDOW()
        ) {
            IStakedAave(stakedAave).redeem(address(this), stakedAaveBalance);
        }

        // 5. Sells the reward AAVE token and the redeemed staked AAVE for obtain more supplying token
        uint256 aaveBalance = IERC20(aave).balanceOf(address(this));
        if (aaveBalance > 0) {
            IERC20(aave).safeIncreaseAllowance(uniswap, aaveBalance);

            address[] memory paths = new address[](3);
            paths[0] = aave;
            paths[1] = weth;
            paths[2] = supplyToken;

            IUniswapV2(uniswap).swapExactTokensForTokens(
                aaveBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );

            // Deposit supplying token to Aave Lending Pool and mint aToken.
            uint256 obtainedSupplyTokenAmount = IERC20(supplyToken).balanceOf(address(this));
            IERC20(supplyToken).safeIncreaseAllowance(lendingPool, obtainedSupplyTokenAmount);
            ILendingPool(lendingPool).deposit(supplyToken, obtainedSupplyTokenAmount, address(this), 0);
        }
    }

    function _buy(uint256 _buyAmount) private {
        // Pull supplying token(e.g. DAI, USDT) from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // Deposit supplying token to Aave Lending Pool and mint aToken.
        IERC20(supplyToken).safeIncreaseAllowance(lendingPool, _buyAmount);
        ILendingPool(lendingPool).deposit(supplyToken, _buyAmount, address(this), 0);
    }

    function _sell(uint256 _sellAmount) private {
        // Withdraw supplying token(e.g. DAI, USDT) from Aave Lending Pool.
        ILendingPool(lendingPool).withdraw(supplyToken, _sellAmount, address(this));

        // Transfer supplying token to Controller
        uint256 supplyTokenBalance = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, supplyTokenBalance);
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
