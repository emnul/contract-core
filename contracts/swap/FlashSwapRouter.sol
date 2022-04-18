// SPDX-License-Identifier: MIT
pragma solidity >=0.6.10 <0.8.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/ITranchessSwapCallee.sol";
import "../interfaces/IPrimaryMarketV3.sol";
import "../interfaces/ISwapRouter.sol";
import "../interfaces/ITrancheIndexV2.sol";

/// @title Tranchess Flash Swap Router
/// @notice Router for stateless execution of flash swaps against Tranchess stable swaps

interface IPancakeRouter01 {
    function factory() external pure returns (address);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract FlashSwapRouter is ITranchessSwapCallee, ITrancheIndexV2 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    enum RouterOption {LEAST_SLIPPAGE, PANCAKE_SWAP}

    IPancakeRouter01 public immutable pancakeRouter;
    ISwapRouter public immutable tranchessRouter;

    constructor(address pancakeRouter_, address tranchessRouter_) public {
        pancakeRouter = IPancakeRouter01(pancakeRouter_);
        tranchessRouter = ISwapRouter(tranchessRouter_);
    }

    function getPrimaryMarket(address primaryMarketOrRouter)
        public
        view
        returns (IPrimaryMarketV3)
    {
        return IPrimaryMarketV3(IPrimaryMarketV3(primaryMarketOrRouter).fund().primaryMarket());
    }

    function buyR(
        address primaryMarketOrRouter,
        uint256 maxQuote,
        address recipient,
        address tokenQuote,
        RouterOption mode,
        uint256 version,
        uint256 outR
    ) external {
        IPrimaryMarketV3 pm = getPrimaryMarket(primaryMarketOrRouter);
        uint256 underlyingAmount;
        uint256 totalQuoteAmount;
        uint256 quoteAmount;
        {
            address tokenUnderlying = pm.fund().tokenUnderlying();
            uint256 inQ = pm.getSplitForB(outR);
            underlyingAmount = pm.getCreationForQ(inQ);
            // Calculate the exact amount of quote asset to pay
            (totalQuoteAmount, mode) = _externalGetAmountsIn(
                mode,
                underlyingAmount,
                tokenQuote,
                tokenUnderlying
            );
            // Arrange the stable swap path
            address[] memory tranchessPath = new address[](2);
            tranchessPath[0] = pm.fund().tokenB();
            tranchessPath[1] = tokenQuote;
            // Calculate the amount of quote asset for selling BISHOP
            quoteAmount = tranchessRouter.getAmountsOut(outR, tranchessPath)[1];
        }
        IStableSwap tranchessPair = tranchessRouter.getSwap(pm.fund().tokenB(), tokenQuote);
        // Send the user's portion of the payment to Tranchess swap
        uint256 resultAmount = totalQuoteAmount.sub(quoteAmount);
        require(resultAmount <= maxQuote, "Insufficient input");
        bytes memory data =
            abi.encode(primaryMarketOrRouter, underlyingAmount, recipient, version, mode);
        IERC20(tokenQuote).safeTransferFrom(msg.sender, address(this), resultAmount);
        tranchessPair.swap(version, 0, quoteAmount, address(this), data);
    }

    function sellR(
        address primaryMarketOrRouter,
        uint256 minQuote,
        address recipient,
        address tokenQuote,
        RouterOption mode,
        uint256 version,
        uint256 inR
    ) external {
        IPrimaryMarketV3 pm = getPrimaryMarket(primaryMarketOrRouter);
        // Send the user's ROOK to this router
        pm.fund().trancheTransferFrom(TRANCHE_R, msg.sender, address(this), inR, version);
        bytes memory data = abi.encode(primaryMarketOrRouter, minQuote, recipient, version, mode);
        tranchessRouter.getSwap(pm.fund().tokenB(), tokenQuote).swap(
            version,
            inR,
            0,
            address(this),
            data
        );
    }

    function tranchessSwapCallback(
        address, /*sender*/
        uint256 baseDeltaOut,
        uint256 quoteDeltaOut,
        bytes calldata data
    ) external override {
        (
            address primaryMarketOrRouter,
            uint256 expectAmount,
            address recipient,
            uint256 version,
            RouterOption mode
        ) = abi.decode(data, (address, uint256, address, uint256, RouterOption));
        IPrimaryMarketV3 pm = getPrimaryMarket(primaryMarketOrRouter);
        address tokenQuote = IStableSwap(msg.sender).quoteAddress();
        require(
            msg.sender == address(tranchessRouter.getSwap(tokenQuote, pm.fund().tokenB())),
            "Tranchess Pair check failed"
        );
        if (baseDeltaOut > 0) {
            require(quoteDeltaOut == 0, "Unidirectional check failed");
            uint256 quoteAmount;
            {
                // Calculate the exact amount of quote asset to pay
                address[] memory tranchessPath = new address[](2);
                tranchessPath[0] = tokenQuote;
                tranchessPath[1] = pm.fund().tokenB();
                quoteAmount = tranchessRouter.getAmountsIn(baseDeltaOut, tranchessPath)[0];
            }
            // Merge BISHOP and ROOK into QUEEN
            uint256 outQ = pm.merge(address(this), baseDeltaOut, version);
            // Redeem QUEEN for underlying
            if (address(pm) != primaryMarketOrRouter) {
                // If primaryMarketOrRouter is a QUEEN Router, transfer QUEEN to
                // the router for redemption
                pm.fund().trancheTransfer(TRANCHE_Q, primaryMarketOrRouter, outQ, version);
            }
            uint256 underlyingAmount =
                IPrimaryMarketV3(primaryMarketOrRouter).redeem(address(this), outQ, 0, version);
            // Trade underlying for quote asset
            uint256 totalQuoteAmount =
                _externalSwap(mode, underlyingAmount, 0, pm.fund().tokenUnderlying(), tokenQuote)[
                    1
                ];
            // Send back quote asset to tranchess swap
            IERC20(tokenQuote).safeTransfer(msg.sender, quoteAmount);
            // Send the rest of quote asset to user
            uint256 resultAmount = totalQuoteAmount.sub(quoteAmount);
            require(resultAmount >= expectAmount, "Insufficient output");
            IERC20(tokenQuote).safeTransfer(recipient, resultAmount);
        } else {
            // Trade quote asset for underlying asset
            uint256 underlyingAmount =
                _externalSwap(
                    mode,
                    quoteDeltaOut,
                    expectAmount,
                    tokenQuote,
                    pm.fund().tokenUnderlying()
                )[1];
            // Create QUEEN using the borrowed underlying
            IERC20(pm.fund().tokenUnderlying()).safeApprove(
                primaryMarketOrRouter,
                underlyingAmount
            );
            uint256 outQ =
                IPrimaryMarketV3(primaryMarketOrRouter).create(
                    address(this),
                    underlyingAmount,
                    0,
                    version
                );
            // Split QUEEN into BISHOP and ROOK
            uint256 outB = pm.split(address(this), outQ, version);
            // Send back BISHOP to tranchess swap
            pm.fund().trancheTransfer(TRANCHE_B, msg.sender, outB, version);
            // Send ROOK to user
            pm.fund().trancheTransfer(TRANCHE_R, recipient, outB, version);
        }
    }

    function _externalGetAmountsIn(
        RouterOption mode,
        uint256 amountOut,
        address tokenIn,
        address tokenOut
    ) private view returns (uint256, RouterOption) {
        if (mode == RouterOption.LEAST_SLIPPAGE) {
            return (_pancakeGetAmountsIn(amountOut, tokenIn, tokenOut), mode);
        } else if (mode == RouterOption.PANCAKE_SWAP) {
            return (_pancakeGetAmountsIn(amountOut, tokenIn, tokenOut), mode);
        } else {
            revert("Invalid external swap");
        }
    }

    function _externalSwap(
        RouterOption mode,
        uint256 amountIn,
        uint256 minAmountOut,
        address tokenIn,
        address tokenOut
    ) private returns (uint256[] memory amounts) {
        if (mode == RouterOption.LEAST_SLIPPAGE) {
            mode = RouterOption.PANCAKE_SWAP;
        }

        if (mode == RouterOption.PANCAKE_SWAP) {
            address[] memory pancakePath = new address[](2);
            pancakePath[0] = tokenIn;
            pancakePath[1] = tokenOut;
            amounts = pancakeRouter.swapExactTokensForTokens(
                amountIn,
                minAmountOut,
                pancakePath,
                address(this),
                block.timestamp
            );
        } else {
            revert("Invalid external swap");
        }
    }

    function _pancakeGetAmountsIn(
        uint256 amountOut,
        address tokenIn,
        address tokenOut
    ) private view returns (uint256 amount) {
        address[] memory pancakePath = new address[](2);
        pancakePath[0] = tokenIn;
        pancakePath[1] = tokenOut;
        amount = pancakeRouter.getAmountsIn(amountOut, pancakePath)[0];
    }

    function _pancakeGetAmountsOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) private view returns (uint256 amount) {
        address[] memory pancakePath = new address[](2);
        pancakePath[0] = tokenIn;
        pancakePath[1] = tokenOut;
        amount = pancakeRouter.getAmountsOut(amountIn, pancakePath)[1];
    }
}
