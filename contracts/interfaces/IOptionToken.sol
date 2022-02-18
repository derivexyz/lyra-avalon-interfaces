//SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// Interfaces
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "./IOptionMarket.sol";

/**
 * @title IOptionToken
 * @author Lyra
 * @dev Provides a tokenised representation of each trade position including amount of options and collateral.
 */
interface IOptionToken is IERC721Enumerable {
  enum PositionState {
    EMPTY,
    ACTIVE,
    CLOSED,
    LIQUIDATED,
    SETTLED,
    MERGED
  }

  struct OptionPosition {
    uint positionId;
    uint listingId;
    IOptionMarket.OptionType optionType;
    uint amount;
    uint collateral;
    PositionState state;
  }

  ///////////////
  // In-memory //
  ///////////////
  struct PositionAndOwner {
    OptionPosition position;
    address owner;
  }

  // to prevent stack too deep...
  struct LiquidationFees {
    uint returnCollateral;
    uint liquidatorFee;
    uint lpFee;
    uint smFee;
    uint insolventAmount;
  }

  ///////////////
  // Variables //
  ///////////////

  function baseURI() external view returns (string memory);

  /////////////////
  // Liquidation //
  /////////////////

  function canLiquidate(
    OptionPosition memory position,
    uint expiry,
    uint strike,
    uint spotPrice
  ) external view returns (bool);

  ///////////////
  // Transfers //
  ///////////////

  // User can split position into desired amount and collateral
  function split(uint positionId, uint newAmount, uint newCollateral, address recipient) external returns (uint newPositionId);

  function merge(uint[] memory positionIds) external;

  //////////
  // Util //
  //////////

  // Note: can possibly run out of gas, don't use in contracts
  function getOwnerPositions(address owner) external view returns (OptionPosition[] memory);

  function getOptionPositions(uint[] memory positionIds) external view returns (PositionAndOwner[] memory);

  function getActiveOptionPositions(uint[] memory positionIds) external view returns (PositionAndOwner[] memory);

  function getPositionAndOwner(uint positionId) external view returns (PositionAndOwner memory);

  function getPositionState(uint positionId) external view returns (PositionState);

}
