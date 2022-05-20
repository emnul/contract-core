// SPDX-License-Identifier: MIT
pragma solidity >=0.6.10 <0.8.0;

interface IStableSwapCore {
    function getQuoteOut(uint256 baseIn) external view returns (uint256 quoteOut);

    function getQuoteIn(uint256 baseOut) external view returns (uint256 quoteIn);

    function getBaseOut(uint256 quoteIn) external view returns (uint256 baseOut);

    function getBaseIn(uint256 quoteOut) external view returns (uint256 baseIn);

    function buy(
        uint256 version,
        uint256 baseOut,
        address recipient,
        bytes calldata data
    ) external returns (uint256 realBaseOut);

    function sell(
        uint256 version,
        uint256 quoteOut,
        address recipient,
        bytes calldata data
    ) external returns (uint256 realQuoteOut);
}

interface IStableSwap is IStableSwapCore {
    function baseAddress() external view returns (address);

    function quoteAddress() external view returns (address);

    function allBalances() external view returns (uint256, uint256);

    function getOraclePrice() external view returns (uint256);

    function getCurrentD() external view returns (uint256);

    function getCurrentPriceOverOracle() external view returns (uint256);

    function getCurrentPrice() external view returns (uint256);

    function getPriceOverOracleIntegral() external view returns (uint256);

    function addLiquidity(uint256 version, address recipient) external returns (uint256);

    function removeLiquidity(
        uint256 version,
        uint256 lpIn,
        uint256 minBaseOut,
        uint256 minQuoteOut
    ) external returns (uint256 baseOut, uint256 quoteOut);

    function removeLiquidityUnwrap(
        uint256 version,
        uint256 lpIn,
        uint256 minBaseOut,
        uint256 minQuoteOut
    ) external returns (uint256 baseOut, uint256 quoteOut);

    function removeBaseLiquidity(
        uint256 version,
        uint256 lpIn,
        uint256 minBaseOut
    ) external returns (uint256 baseOut);

    function removeQuoteLiquidity(
        uint256 version,
        uint256 lpIn,
        uint256 minQuoteOut
    ) external returns (uint256 quoteOut);

    function removeQuoteLiquidityUnwrap(
        uint256 version,
        uint256 lpIn,
        uint256 minQuoteOut
    ) external returns (uint256 quoteOut);
}
