# Trader Example

In this guide, we will build a simple contract that purchases call options from the Lyra AMM. 

1. [Import LyraAdapter.sol](#setup)
2. [Open trades determined by the owner](#open)
3. [Adjust existing positions](#existing)
4. [Force close](#force)
4. [Position settling](#settle)
5. [Common revert scenarios](#reverts)
6. [Trading rewards](#rewards)

We use the terminology - `base` to denote the option asset and `quote` to represent the unit of pricing. For the ETH market `quote` is sUSD and `base` is sETH.

## Import LyraAdapter.sol <a name="setup"></a>

We will use the `LyraAdapter.sol` contract to get all Lyra related functionality in one contract. Install the [@lyrafinance/protocol](https://www.npmjs.com/package/@lyrafinance/protocol) package and follow the setup instructions.

```solidity
pragma solidity 0.8.9;
import {LyraAdapter} from "@lyrafinance/protocol/contracts/periphery/LyraAdapter.sol";

// Libraries
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TraderExample is LyraAdapter {
  constructor() LyraAdapter()
  uint[] public activePositionIds;
    
  function initAdapter(
    address _lyraRegistry,
    address _optionMarket,
    address _curveSwap,
    address _feeCounter
  ) external onlyOwner {
    // set addresses for LyraAdapter
    setLyraAddresses(_lyraRegistry, _optionMarket, _curveSwap, _feeCounter);
  }
}
```

Call `getMarketDeploys` via [@lyrafinance/protocol](https://www.npmjs.com/package/@lyrafinance/protocol) to get required addresses.
## Open a new position <a name="open"></a>

Lyra options are organized by `OptionMarket`, `boardId`, `strikeId` and `positionId`:
* `OptionMarket` - contract/address that manages options for an underlying `base`/`quote` pair (e.g. ETH/USD)
* `boardId` - contains multiple strikes sharing the same expiry (e.g. all strikes that expire August 24th, 2022)
* `strikeId` - signifies all `optionTypes` with the same strike price ($1500 strike for the August 24th, 2022 board)
* `positionId` - single ERC721 option position (a trader can open several positions per strikeId)

Each position must choose an `optionType` - long/short; call/put; base/quote collateralized, specified by the following enum: 

```solidity
enum LyraAdapter.OptionType {
  LONG_CALL,
  LONG_PUT,
  SHORT_CALL_BASE, // base collateral
  SHORT_CALL_QUOTE, // quote collateral
  SHORT_PUT_QUOTE // quote collateral
}
```

When opening/adjusting a position, we need to consider 4 more params:

* `setCollateralTo` - for shorts, what collateral should be remaining for the position after the trade
* `minTotalCost/maxTotalCost` - boundaries for the `totalCost` (premium + volatility slippage + fees) at trade execution (otherwise revert)
* `iterations` - number of sub orders to cut into (only relevant for very large orders). This helps optimize the black-scholes price for very large trades (refer to [appendix C](https://www.lyra.finance/files/whitepaper.pdf) of the whitepaper for more details). 

Let's create a simple wrapper function which the `Owner` can call to open any position. `LyraAdapter.sol` contains all the needed data types to complete this order.

```solidity

function openNewPosition(uint strikeId, OptionMarket.OptionType optionType, uint amount, uint setCollateralTo) external onlyOwner {
  TradeInputParameters tradeParams = TradeInputParameters({
    strikeId: strikeId,
    positionId: 0, // if 0, new position is created
    iterations: 3, // more iterations use more gas but incur less slippage
    optionType: optionType,
    amount: 10,
    setCollateralTo: setCollateralTo, // set to 0 if opening long
    minTotalCost: 0,
    maxTotalCost: type(uint).max,
  }
  TradeResult result = _openPosition(tradeParams); // built-in LyraAdapter.sol function
  activePositionIds.push(result.positionId);
}
```
*Note: For the sake of simplicity, we have removed units from these function calls. In reality, these values would be multiplied by the unit of the tokens (1e18).*

## Get existing position details <a name="getter"></a>

Use the built-in `LyraAdapter.sol` position getter and struct.

```solidity
OptionPosition position = _getPositions([1, 2, 3]); // get positions with IDs #1, #2, #3
```

For reference: 
```solidity
struct LyraAdapter.OptionPosition {
  // OptionToken ERC721 identifier for position
  uint positionId;
  // strike identifier
  uint strikeId;
  // LONG_CALL | LONG_PUT | SHORT_CALL_BASE | SHORT_CALL_QUOTE | SHORT_PUT_QUOTE
  OptionType optionType;
  // number of options contract owned by position
  uint amount;
  // collateral held in position (only applies to shorts)
  uint collateral;
  // EMPTY | ACTIVE | CLOSED | LIQUIDATED | SETTLED | MERGED
  PositionState state;
}
```

## Adjust existing position amount and collateral  <a name="existing"></a>

Now, let's do a more complex trade
* close only 50% of the current `position.amount`
* but at the same time increase `position.collateral` by some amount

We use the same `TradeInputParameters` struct but this time we call `closePosition` as we are reducing the position amount. Let's use the same `position` variable to fill in the static params.

```solidity
function reducePositionAndAddCollateral(uint positionId, uint reduceAmount, uint addCollatAmount, bool isForceClose) external onlyOwner{
  Position position = _getPositions(_singletonArray(positionId)); // must first convert number into a static array

  TradeInputParameters tradeParams = TradeInputParameters({
    strikeId: position.strikeId,
    positionId: position.positionId,
    iterations: 3,
    optionType: position.optionType,
    amount: position.amount / 2, // closing 50%
    setCollateralTo: position.collateral + addCollatAmount, // increase collateral by addCollatAmount
    minTotalCost: 0,
    maxTotalCost: type(uint).max, // assume we are ok with any premium amount
  }

  // built-in LyraAdapter.sol functions
  if (!isForceClose) {
    _closePosition(tradeParams);
  } else {
    _forceClosePosition(tradeParams);
  }
}
```

If we were to set `TradeInputParams.amount` = `position.amount`, the position would be fully closed and `position.state` would be set to `CLOSED`. This will send back all the position collateral for shorts regardless of the `setCollateralTo` input.

## Force Closing (a.k.a Universal Closing)  <a name="force"></a>

When reducing the position in the above function, we gave the owner two options. Traders can either call `_closePosition()` which works for positions within a certain delta range (~8-92) or use `_forceClosePosition()` to reduce amount on positions with deltas beyond the range or options that are very close to expiry in exchange for a fee. `LyraAdapter.sol` provides a `_closeOrForceClosePosition()` alternative which will automatically decide the best option depending on delta/cutoff conditions.

The order flow/logic of `OptionMarket.forceClose()` and `OptionMarket.liquidate()` have two distinct features that differentiate them from `closePosition`.
* GWAV `skew` * `vol` * penalty (instead of the AMM spot skew * vol) are used to compute the black-scholes price
* The AMM only applies slippage to the `skew` (and not `baseIv`)

*Refer to [`OptionGreekCache.getPriceForForceClose()`](https://github.com/lyra-finance/lyra-protocol/blob/avalon/contracts/OptionGreekCache.sol) for the exact mechanism*

## Settle expired position  <a name="settle"></a>

Once `block.timestamp` > the listing `expiry`, Lyra keepers auto-settle everyone's expired positions via `ShortCollateral.settleOptions(uint[] positionIds)`.However, anyone can settle positions manually if they wish to.

### Settle scenarios:

* LONG_CALL
  * `if spot > strike: amount * (spot - strike)` reserved per option to pay out to the user (in quote)
* LONG_PUT
  * `if spot < strike: amount * (strike - spot)` reserved per option to pay out to the user (in quote)
* SHORT_CALL_BASE
  * `if spot > strike: amount * (spot - strike)` paid to LP from `position.collateral` (automatically converted to quote)
  * remainder is sent to trader in `base`
* SHORT_CALL_QUOTE
  * `if spot > strike: amount * (spot - strike)` paid to LP from `position.collateral` (in quote)
  * remainder is sent to trader in `quote`
* SHORT_PUT_QUOTE
  * `if spot < strike: amount * (strike - spot)` paid to LP from `position.collateral` (in quote)
  * remainder is sent to trader in `quote`

## Common revert scenarios  <a name="reverts"></a>

| custom error                                    | contract            | description                         |
| ----------------------------------------------- | --------------------|------------------------------------ |
| TotalCostOutsideOfSpecifiedBounds               | OptionMarket        | `totalCost` < minCost or > maxCost
| ExpectedNonZeroValue                            | OptionMarket        | iterations or strikeId cannot be 0
| BoardIsFrozen                                   | OptionMarket        | admin has frozen board
| BoardExpired                                    | OptionMarket        | listing `expiry` < `block.timestamp`
| insufficient funds                              | ERC20               | LP or trader does not have sufficient funds
| TradeDeltaOutOfRange                            | OptionMarketPricer  | opening/closing outside of delta range, use `forceClose` to bypass
| ForceCloseDeltaOutOfRange                       | OptionMarketPricer  | force closing outside the forceCloseDeltaRange, use `forceClose` to bypass
| TradingCutoffReached                            | OptionMarketPricer  | opening/closing too close to expiry, use `forceClose` to bypass
| AdjustmentResultsInMinimumCollateralNotBeingMet | OptionToken         | new collateral < minimum required collateral
| FullyClosingWithNonZeroSetCollateral            | OptionToken         | when fully closing `setCollateralTo` must equal 0
| OnlyOwnerCanAdjustPosition                      | OptionToken         | `position.owner` must equal `msg.sender`
| CannotAdjustInvalidPosition                     | OptionToken         | `position.state` must be `ACTIVE` or `TradeInputParameters` do no match `positionId`
| BoardMustBeSettled                              | ShortCollateral     | `OptionMarket.settleBoard` has not been called

## Trading Rewards

Refer to [Overview](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/examples/Intro.md)