# Trader Example

In this guide, we will build a contract that interacts directly with the core Lyra contracts:
1. [Setup a simple trader contract](#setup)
2. [Open trades determined by the owner](#open)
3. [Adjust existing positions](#existing)
4. [Force close](#force)
4. [Position settling](#settle)
5. [Common revert scenarios](#reverts)

We use the terminology - `base` to denote the option asset and `quote` to represent the unit of pricing. For the ETH market `quote` is sUSD and `base` is sETH.

*Note: To learn how to interact with Lyra via the VaultAdapter, refer to: [lyra-vaults](https://github.com/lyra-finance/lyra-vaults) or the [CollateralManager](...) example*

## Setup simple trader contract <a name="setup"></a>

To perform actions in this guide, we will need to import [OptionMarket.sol](https://github.com/lyra-finance/lyra-protocol/blob/master/contracts/OptionMarket.sol), [OptionToken.sol](https://github.com/lyra-finance/lyra-protocol/blob/master/contracts/OptionToken.sol) and [ShortCollateral.sol](https://github.com/lyra-finance/lyra-protocol/blob/master/contracts/ShortCollateral.sol). 

Install the [@lyrafinance/protocol](https://www.npmjs.com/package/@lyrafinance/protocol) package and follow the setup instructions.

```solidity
pragma solidity 0.8.9;
import {OptionMarket} from "@lyrafinance/protocol/contracts/OptionMarket.sol";
import {OptionToken} from "@lyrafinance/protocol/contracts/OptionToken.sol";
import {ShortCollateral} from "@lyrafinance/protocol/contracts/ShortCollateral.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TraderExample is Ownable {
    IOptionMarket public optionMarket;
    IOptionToken public optionToken;
    IShortCollateral public shortCollateral;
    IERC20 internal quoteAsset;
    IERC20 internal baseAsset;

    uint[] public activePositionIds;

    constructor( 
      IOptionMarket _ethMarketAddress, 
      IOptionToken _ethOptionToken,
      IShortCollateral _ethShortCollateral,
      IERC20 _quoteAsset,
      IERC20 _baseAsset
    ) Ownable() {
      optionMarket = _ethMarketAddress; 
      optionToken = _ethOptionToken; 
      shortCollateral = _ethShortCollateral;
      quoteAsset = _quoteAsset;
      baseAsset = _baseAsset;

      quoteAsset.approve(address(this), type(uint).max);
      baseAsset.approve(address(this), type(uint).max);
    }
}
```
Call `getMarketDeploys` via [@lyrafinance/protocol](https://www.npmjs.com/package/@lyrafinance/protocol) to get addresses of different `base`/`quote` option markets.

## Open a new position <a name="open"></a>

Lyra options are organized by `OptionMarket`, `boardId`, `strikeId` and `positionId`:
* `OptionMarket` - contract/address that manages options for an underlying `base`/`quote` pair (e.g. ETH/USD)
* `boardId` - contains multiple strikes sharing the same expiry (e.g. all strikes that expire August 24th, 2022)
* `strikeId` - signifies all `optionTypes` with the same strike price ($1500 strike for the August 24th, 2022 board)
* `positionId` - single ERC721 option position (a trader can open several positions per strikeId)

Each position must choose an `optionType` - long/short; call/put; base/quote collateralized, specified by the following enum: 

```solidity
enum OptionMarket.OptionType {
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

Let's create a simple wrapper function which the `Owner` can call to open any position.

```solidity

function openNewPosition(uint strikeId, OptionMarket.OptionType optionType, uint amount, uint setCollateralTo) external onlyOwner {
  OptionMarket.TradeInputParameters tradeParams = OptionMarket.TradeInputParameters({
    strikeId: strikeId,
    positionId: 0, // if 0, new position is created
    iterations: 3, // more iterations use more gas but incur less slippage
    optionType: optionType,
    amount: 10,
    setCollateralTo: setCollateralTo, // set to 0 if opening long
    minTotalCost: 0,
    maxTotalCost: type(uint).max,
  }
  OptionMarket.Result result = optionMarket.openPosition(tradeParams);
  activePositionIds.push(result.positionId);
}
```
*Note: For the sake of simplicity, we have removed units from these function calls. In reality, these values would be multiplied by the unit of the tokens (1e18).*


## Get existing position details <a name="getter"></a>

We can retreive all details of our position we just opened using the `positionId`.

```solidity
OptionToken.PositionWithOwner position = optionToken.getPositionWithOwner(positionId);
```

>Use the `getOptionPositions(uint[] positionIds)` function to get multiple positions in one call.

```solidity
struct PositionWithOwner {
    uint positionId;
    uint listingId;
    OptionMarket.OptionType optionType;
    uint amount;
    uint collateral;
    PositionState state; // EMPTY, ACTIVE, CLOSED, LIQUIDATED, SETTLED, or MERGED
    address owner;
}
```

## Adjust existing position amount and collateral  <a name="existing"></a>

Now, let's do a more complex trade
* close only 50% of the current `position.amount`
* but at the same time increase `position.collateral` by some amount

We use the same `TradeInputParameters` struct but this time we call `closePosition` as we are reducing the position amount. Let's use the same `position` variable to fill in the static params.

```solidity
function reducePositionAndAddCollateral(uint positionId, uint reduceAmount, uint addCollatAmount, bool isForceClose) external onlyOwner{
  OptionToken.PositionWithOwner position = optionToken.getPositionWithOwner(positionId);

  IOptionMarket.TradeInputParameters tradeParams = IOptionMarket.TradeInputParameters({
    strikeId: position.strikeId,
    positionId: position.positionId,
    iterations: 3,
    optionType: position.optionType,
    amount: position.amount / 2, // closing 50%
    setCollateralTo: position.collateral + addCollatAmount, // increase collateral by addCollatAmount
    minTotalCost: 0,
    maxTotalCost: type(uint).max, // assume we are ok with any premium amount
  }

  if (!isForceClose) {
    optionMarket.closePosition(tradeParams);
  } else {
    optionMarket.forceClosePosition(tradeParams);
  }
}
```

If we were to set `TradeInputParams.amount` = `position.amount`, the position would be fully closed and `position.state` would be set to `CLOSED`. This will send back all the position collateral for shorts regardless of the `setCollateralTo` input.

## Force Closing (a.k.a Universal Closing)  <a name="force"></a>

When reducing the position in the above function, we gave the owner two options. Traders can either call `closePosition` which works for positions within a certain delta range (~8-92) or use `forceClosePosition` to reduce amount on positions with deltas beyond the range or options that are very close to expiry in exchange for a fee.

The order flow/logic of `OptionMarket.forceClose()` and `OptionMarket.liquidate()` have two distinct features that differentiate them from `closePosition`.
* GWAV `skew` * `vol` * penalty (instead of the AMM spot skew * vol) are used to compute the black-scholes price
* The AMM only applies slippage to the `skew` (and not `baseIv`)

*Refer to [`OptionGreekCache.getPriceForForceClose()`](https://github.com/lyra-finance/lyra-protocol/blob/master/contracts/OptionGreekCache.sol) for the exact mechanism*

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

