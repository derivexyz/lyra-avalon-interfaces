//SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "./IOptionToken.sol";
import "./IOptionMarketPricer.sol";

/**
 * @title IOptionMarket
 * @author Lyra
 * @dev An AMM which allows users to trade options. Supports both buying and selling options, which determine the value
 * for the listing's IV. Also allows for auto cash settling options as at expiry.
 */
interface IOptionMarket {

  enum OptionType {
    LONG_CALL,
    LONG_PUT,
    SHORT_CALL_BASE,
    SHORT_CALL_QUOTE,
    SHORT_PUT_QUOTE
  }

  ///////////////////
  // Internal data //
  ///////////////////

  struct OptionListing {
    uint id;
    uint strike;
    uint skew;
    uint longCall;
    uint shortCallBase;
    uint shortCallQuote;
    uint longPut;
    uint shortPut;
    uint boardId;
  }

  struct OptionBoard {
    uint id;
    uint expiry;
    uint iv;
    bool frozen;
    uint[] listingIds;
  }

  ///////////////
  // In-memory //
  ///////////////

  struct TradeInputParameters {
    uint listingId;
    uint positionId;
    uint iterations;
    OptionType optionType;
    uint amount;
    uint setCollateralTo;
    uint minTotalCost;
    uint maxTotalCost;
  }

  struct Result {
    uint positionId;
    uint totalCost;
    uint totalFee;
  }

  ///////////////
  // Variables //
  ///////////////

  function boardToPriceAtExpiry(uint boardId) external returns (uint priceAtExpiry);
  function listingToBaseReturnedRatio(uint listingId) external returns (uint baseReturned);

  ///////////
  // Views //
  ///////////

  /**
   * @dev Returns the list of live board ids.
   */
  function getLiveBoards() external view returns (uint[] memory _liveBoards);

  function getNumLiveBoards() external view returns (uint numLiveBoards);

  /**
   * @dev Returns the listing ids for a given `boardId`.
   *
   * @param boardId The id of the relevant OptionBoard.
   */
  function getBoardListings(uint boardId) external view returns (uint[] memory);

  function getOptionListing(uint listingId) external view returns (OptionListing memory);

  function getOptionBoard(uint boardId) external view returns (OptionBoard memory);

  ////////////////////
  // User functions //
  ////////////////////

  function openPosition(TradeInputParameters memory params) external returns (Result memory result);

  function closePosition(TradeInputParameters memory params) external returns (Result memory result);

  function forceClosePosition(TradeInputParameters memory params) external returns (Result memory result);

  function addCollateral(uint positionId, uint amountCollateral) external;

  /////////////////
  // Liquidation //
  /////////////////

  function liquidatePosition(uint positionId, address rewardBeneficiary) external;

  /////////////////////////////////
  // Board Expiry and settlement //
  /////////////////////////////////

  /**
   * @dev Settle a board that has passed expiry. This function will not preserve the ordering of liveBoards.
   *
   * @param boardId The id of the relevant OptionBoard.
   */
  function settleExpiredBoard(uint boardId) external;

  function getSettlementParameters(uint listingId)
  external
  view
  returns (
    uint strike,
    uint priceAtExpiry,
    uint listingToBaseReturned
  );

  //////////
  // Misc //
  //////////

  function getListingStrikeExpiry(uint listingId) external view returns (uint strike, uint expiry);

  ////////////
  // Events //
  ////////////

  /**
   * @dev Emitted when a Board is created.
   */
  event BoardCreated(uint indexed boardId, uint expiry, uint baseIv, bool frozen);

  /**
   * @dev Emitted when a Board frozen is updated.
   */
  event BoardFrozen(uint indexed boardId, bool frozen);

  /**
   * @dev Emitted when a Board new baseIv is set.
   */
  event BoardBaseIvSet(uint indexed boardId, uint baseIv);

  /**
   * @dev Emitted when a Listing new skew is set.
   */
  event ListingSkewSet(uint indexed listingId, uint skew);

  /**
   * @dev Emitted when a Listing is added to a board
   */
  event ListingAdded(uint indexed boardId, uint indexed listingId, uint strike, uint skew);

  /**
   * @dev Emitted when a Position is opened.
   */
  event PositionOpened(
    address indexed trader,
    uint indexed listingId,
    uint indexed positionId,
    OptionType optionType,
    uint amount,
    uint totalCost,
    IOptionMarketPricer.TradeResult[] tradeResults
  );

  /**
   * @dev Emitted when a Position is closed.
   */
  event PositionClosed(
    address indexed trader,
    uint indexed listingId,
    uint indexed positionId,
    OptionType optionType,
    uint amount,
    bool isForceClose,
    uint totalCost,
    IOptionMarketPricer.TradeResult[] tradeResults
  );

  event PositionLiquidated(
    uint indexed positionId,
    address indexed rewardBeneficiary,
    address indexed positionOwner,
    address caller,
    IOptionToken.LiquidationFees liquidationFees,
    uint listingId,
    OptionType optionType,
    IOptionMarketPricer.TradeResult[] tradeResults
  );

  /**
   * @dev Emitted when a Board is liquidated.
   */
  event BoardSettled(
    uint indexed boardId,
    uint totalUserLongProfitQuote,
    uint totalBoardLongCallCollateral,
    uint totalBoardLongPutCollateral,
    uint totalAMMShortCallProfitBase,
    uint totalAMMShortCallProfitQuote,
    uint totalAMMShortPutProfitQuote
  );
}
