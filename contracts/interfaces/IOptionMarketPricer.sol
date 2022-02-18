//SPDX-License-Identifier: ISC
pragma solidity 0.8.9;
/**
 * @title IOptionMarketPricer
 * @author Lyra
 * @dev Logic for working out the price of an option. Includes the IV impact of the trade, the fee components and
 * premium.
 */
interface IOptionMarketPricer {
  struct TradeResult {
    uint premium;
    uint optionPriceFee;
    uint spotPriceFee;
    uint vegaUtilFee;
    uint totalCost;
    uint volTraded;
    uint newBaseIv;
    uint newSkew;
  }
}
