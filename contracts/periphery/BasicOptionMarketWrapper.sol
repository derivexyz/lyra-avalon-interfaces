//SPDX-License-Identifier:ISC
pragma solidity 0.8.9;

import "../interfaces/IOptionMarket.sol";
import "../interfaces/IOptionToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BasicOptionMarketWrapper
 * NOTE: This is untested, just an example of the expected operations a contract trying to integrate would need to
 *       implement
 */
contract BasicOptionMarketWrapper is Ownable {
  struct IOptionMarketContracts {
    IERC20 quoteAsset;
    IERC20 baseAsset;
    IOptionToken optionToken;
  }

  mapping(IOptionMarket => IOptionMarketContracts) marketContracts;

  constructor() Ownable() {}

  function updateMarket(IOptionMarket optionMarket, IOptionMarketContracts memory _marketContracts) external onlyOwner {
    marketContracts[optionMarket] = _marketContracts;

    marketContracts[optionMarket].quoteAsset.approve(address(optionMarket), type(uint).max);
    marketContracts[optionMarket].baseAsset.approve(address(optionMarket), type(uint).max);
  }

  function openPosition(
    IOptionMarket optionMarket,
    IOptionMarket.TradeInputParameters memory params,
    uint extraCollateral
  ) external returns (IOptionMarket.Result memory result) {
    IOptionMarketContracts memory c = marketContracts[optionMarket];

    if (params.positionId != 0) {
      c.optionToken.transferFrom(msg.sender, address(this), params.positionId);
    }

    _takeExtraCollateral(c, params.optionType, extraCollateral);

    result = optionMarket.openPosition(params);

    _returnExcessFunds(c);

    c.optionToken.transferFrom(address(this), msg.sender, result.positionId);
  }

  function closePosition(
    IOptionMarket optionMarket,
    IOptionMarket.TradeInputParameters memory params,
    uint extraCollateral
  ) external returns (IOptionMarket.Result memory result) {
    IOptionMarketContracts memory c = marketContracts[optionMarket];

    if (params.positionId != 0) {
      c.optionToken.transferFrom(msg.sender, address(this), params.positionId);
    }

    _takeExtraCollateral(c, params.optionType, extraCollateral);

    result = optionMarket.closePosition(params);

    _returnExcessFunds(c);

    if (c.optionToken.getPositionState(result.positionId) == IOptionToken.PositionState.ACTIVE) {
      c.optionToken.transferFrom(address(this), msg.sender, params.positionId);
    }
  }

  function forceClosePosition(
    IOptionMarket optionMarket,
    IOptionMarket.TradeInputParameters memory params,
    uint extraCollateral
  ) external returns (IOptionMarket.Result memory result) {
    IOptionMarketContracts memory c = marketContracts[optionMarket];

    if (params.positionId != 0) {
      c.optionToken.transferFrom(msg.sender, address(this), params.positionId);
    }

    _takeExtraCollateral(c, params.optionType, extraCollateral);

    result = optionMarket.forceClosePosition(params);

    _returnExcessFunds(c);

    if (c.optionToken.getPositionState(result.positionId) == IOptionToken.PositionState.ACTIVE) {
      c.optionToken.transferFrom(address(this), msg.sender, params.positionId);
    }
  }

  function _takeExtraCollateral(
    IOptionMarketContracts memory c,
    IOptionMarket.OptionType optionType,
    uint extraCollateral
  ) internal {
    if (!_isLong(optionType)) {
      if (extraCollateral != 0) {
        if (_isBaseCollateral(optionType)) {
          c.baseAsset.transferFrom(msg.sender, address(this), extraCollateral);
        } else {
          c.quoteAsset.transferFrom(msg.sender, address(this), extraCollateral);
        }
      }
    }
  }

  function _returnExcessFunds(IOptionMarketContracts memory c) internal {
    uint quoteBal = c.quoteAsset.balanceOf(address(this));
    if (quoteBal > 0) {
      c.quoteAsset.transfer(msg.sender, quoteBal);
    }
    uint baseBal = c.baseAsset.balanceOf(address(this));
    if (baseBal > 0) {
      c.baseAsset.transfer(msg.sender, baseBal);
    }
  }

  function _isLong(IOptionMarket.OptionType optionType) internal pure returns (bool) {
    return (optionType < IOptionMarket.OptionType.SHORT_CALL_BASE);
  }

  function _isCall(IOptionMarket.OptionType optionType) internal pure returns (bool) {
    return (optionType != IOptionMarket.OptionType.SHORT_PUT_QUOTE || optionType != IOptionMarket.OptionType.LONG_PUT);
  }

  function _isBaseCollateral(IOptionMarket.OptionType optionType) internal pure returns (bool) {
    return (optionType == IOptionMarket.OptionType.SHORT_CALL_BASE);
  }
}
