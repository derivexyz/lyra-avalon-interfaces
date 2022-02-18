//SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "./IOptionMarket.sol";

/**
 * @title IShortCollateral
 * @author Lyra
 * @dev Holds collateral from users who are selling (shorting) options to the OptionMarket.
 */
interface IShortCollateral {


  ///////////////
  // Variables //
  ///////////////

  function LPBaseExcess() external returns (uint);
  function LPQuoteExcess() external returns (uint);

  ///////////////
  // Functions //
  ///////////////


  function settleOptions(uint[] memory positionIds) external returns (uint[] memory settlementAmounts);

  ////////////
  // Events //
  ////////////

  /**
   * @dev Emitted when an Option is settled.
   */
  event PositionSettled(
    uint indexed positionId,
    address indexed settler,
    address indexed optionOwner,
    uint strike,
    uint priceAtExpiry,
    IOptionMarket.OptionType optionType,
    uint amount
  );

  /**
   * @dev Emitted when quote is sent to either a user or the LiquidityPool
   */
  event QuoteSent(address indexed receiver, uint amount);
  /**
   * @dev Emitted when base is sent to either a user or the LiquidityPool
   */
  event BaseSent(address indexed receiver, uint amount);

  event BaseExchangedAndQuoteSent(address indexed recipient, uint amountBase, uint quoteReceived);
}
