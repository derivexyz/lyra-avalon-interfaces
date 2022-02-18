//SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// Interfaces
import "../lib/BlackScholes.sol";
import "../lib/GWAV.sol";
import "./IOptionMarket.sol";

/**
 * @title IOptionGreekCache
 * @author Lyra
 * @dev Aggregates the netDelta and netStdVega of the OptionMarket by iterating over current listings.
 * Needs to be called by an external actor as it's not feasible to do all the computation during the trade flow and
 * because delta/vega change over time and with movements in asset price and volatility.
 * All stored values in this contract are the aggregate of the trader's perspective. So values need to be inverted
 * to get the LP's perspective
 */
interface IOptionGreekCache {

  ///////////////////
  // Cache storage //
  ///////////////////
  struct GlobalCache {
    uint minUpdatedAt;
    uint minUpdatedAtPrice;
    uint maxUpdatedAtPrice;
    uint maxSkewVariance;
    uint maxIvVariance;
    NetGreeks netGreeks;
  }

  struct OptionBoardCache {
    uint id;
    uint[] listings;
    uint expiry;
    uint iv;
    NetGreeks netGreeks;
    uint updatedAt;
    uint updatedAtPrice;
    uint maxSkewVariance;
    uint ivVariance;
  }

  struct OptionListingCache {
    uint id;
    uint boardId;
    uint strike;
    uint skew;
    ListingGreeks greeks;
    int callExposure; // long - short
    int putExposure; // long - short
    uint skewVariance; // (GWAVSkew - skew)
  }

  // These are based on GWAVed iv
  struct ListingGreeks {
    int callDelta;
    int putDelta;
    uint stdVega;
    uint callPrice;
    uint putPrice;
  }

  // These are based on GWAVed iv
  struct NetGreeks {
    int netDelta;
    int netStdVega;
    int netOptionValue;
  }

  ///////////////
  // Variables //
  ///////////////
  function boardIVGWAV(uint boardId) external returns (GWAV.Params memory);
  function listingSkewGWAV(uint listingId) external returns (GWAV.Params memory);

  /////////////////////////////////////
  // Liquidation/Force Close pricing //
  /////////////////////////////////////

  function getMinCollateral(
    IOptionMarket.OptionType optionType,
    uint strike,
    uint expiry,
    uint spotPrice,
    uint amount
  ) external view returns (uint);

  //////////////////////////////////////////
  // Update GWAV vol greeks and net greeks //
  //////////////////////////////////////////

  /**
   * @notice Updates the cached greeks for an OptionBoardCache.
   *
   * @param boardCacheId The id of the OptionBoardCache.
   */
  function updateBoardCachedGreeks(uint boardCacheId) external;

  //////////////////////////
  // Stale cache checking //
  //////////////////////////

  function getVolVariance() external view returns (uint maxIvVariance, uint maxSkewVariance);
  function isGlobalCacheStale(uint spotPrice) external view returns (bool);
  function isBoardCacheStale(uint boardId) external view returns (bool);

  /////////////////////////////
  // External View functions //
  /////////////////////////////

  /**
   * @dev Get the current cached global netDelta value.
   */
  function getGlobalNetDelta() external view returns (int);
  function getGlobalOptionValue() external view returns (int);
  function getOptionListingCache(uint listingId) external view returns (OptionListingCache memory);
  function getOptionBoardCache(uint boardId) external view returns (OptionBoardCache memory);
  function getGlobalCache() external view returns (GlobalCache memory);

  ////////////
  // Events //
  ////////////
  event ListingCacheUpdated(OptionListingCache listingCache);
  event BoardCacheUpdated(OptionBoardCache boardCache);
  event GlobalCacheUpdated(GlobalCache globalCache);

  event BoardCacheRemoved(uint boardId);
  event ListingCacheRemoved(uint listingId);
  event BoardIvUpdated(uint boardId, uint newIv, uint globalMaxIvVariance);
  event ListingSkewUpdated(uint listingId, uint newSkew, uint globalMaxSkewVariance);
}
