// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/compound/ICErc20.sol";
import "../interfaces/compound/IComptroller.sol";
import "../interfaces/uniswap/IUniswapV2.sol";

/**
 * Deposits ERC20 token into Compound Lending Pool and issues stCompoundLendingToken(e.g. stCompoundLendingDAI) in L2. Holds cToken (Compound interest-bearing tokens).
 */
contract StrategyCompoundErc20LendingPool is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of supplying token (e.g. DAI, USDT)
    address public supplyToken;

    // The address of Compound interest-bearing token (e.g. cDAI, cUSDT)
    address public cErc20;

    // The address is used for claim COMP token
    address public comptroller;
    // The address of COMP token
    address public comp;

    address public uniswap;
    // The address of WETH token
    address public weth;

    address public controller;

    uint256 internal constant MAX_INT = 2**256 - 1;
    uint256 internal constant PRICE_PRECISION = 1e18;
    uint256 public shares;

    constructor(
        address _supplyToken,
        address _cErc20,
        address _comptroller,
        address _comp,
        address _uniswap,
        address _weth,
        address _controller
    ) {
        supplyToken = _supplyToken;
        cErc20 = _cErc20;
        comptroller = _comptroller;
        comp = _comp;
        uniswap = _uniswap;
        weth = _weth;
        controller = _controller;
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
        uint256 assetAmount = ICErc20(cErc20).balanceOfUnderlying(address(this));
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

        uint256 newAssetAmount = ICErc20(cErc20).balanceOfUnderlying(address(this));
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

    function syncPrice() external override returns (uint256) {
        uint256 assetAmount = ICErc20(cErc20).balanceOfUnderlying(address(this));
        if (shares == 0) {
            if (assetAmount == 0) {
                return PRICE_PRECISION;
            }
            return MAX_INT;
        }
        return (assetAmount * PRICE_PRECISION) / shares;
    }

    function harvest() external override onlyEOA {
        // Claim COMP token.
        IComptroller(comptroller).claimComp(address(this));
        uint256 compBalance = IERC20(comp).balanceOf(address(this));
        if (compBalance > 0) {
            // Sell COMP token for obtain more supplying token(e.g. DAI, USDT)
            IERC20(comp).safeIncreaseAllowance(uniswap, compBalance);

            address[] memory paths = new address[](3);
            paths[0] = comp;
            paths[1] = weth;
            paths[2] = supplyToken;

            IUniswapV2(uniswap).swapExactTokensForTokens(
                compBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );

            // Deposit supplying token to Compound Erc20 Lending Pool and mint cToken.
            uint256 obtainedSupplyTokenAmount = IERC20(supplyToken).balanceOf(address(this));
            IERC20(supplyToken).safeIncreaseAllowance(cErc20, obtainedSupplyTokenAmount);
            uint256 mintResult = ICErc20(cErc20).mint(obtainedSupplyTokenAmount);
            require(mintResult == 0, "Couldn't mint cToken");
        }
    }

    function _buy(uint256 _buyAmount) private {
        // Pull supplying token(e.g. DAI, USDT) from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // Deposit supplying token to Compound Erc20 Lending Pool and mint cErc20.
        IERC20(supplyToken).safeIncreaseAllowance(cErc20, _buyAmount);
        uint256 mintResult = ICErc20(cErc20).mint(_buyAmount);
        require(mintResult == 0, "Couldn't mint cToken");
    }

    function _sell(uint256 _sellAmount) private {
        // Withdraw supplying token from Compound Erc20 Lending Pool
        // based on an amount of the supplying token(e.g. DAI, USDT).
        uint256 redeemResult = ICErc20(cErc20).redeemUnderlying(_sellAmount);
        require(redeemResult == 0, "Couldn't redeem cToken");

        // Transfer supplying token(e.g. DAI, USDT) to Controller
        uint256 supplyTokenBalance = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, supplyTokenBalance);
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
