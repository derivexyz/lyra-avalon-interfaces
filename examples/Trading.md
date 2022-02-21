# Trading Example

In this guide, we will walk through all the basic trading actions:
- [x] Setup contract
- [x] Open a new position
- [x] Get existing option position details
- [x] Adjust position amount and collateral
- [x] Settle expired position
- [x] Common revert scenarios
- [x] Note on `forceClose`

We use the terminology - `base` to denote the option asset and `quote` to represent the unit of pricing. For the ETH market `quote` is sUSD and `base` is sETH.

*Note: For the sake of simplicity, we have removed units from these function calls. In reality, these values would be multiplied by the unit of the tokens (1e18).*

## Setup contract

To perform actions in this guide, we will need to connect to [IOptionMarket](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionMarket.sol), [IOptionToken](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionToken.sol) and [IShortCollateral](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IShortCollateral.sol).

```solidity
pragma solidity 0.8.9;
import "../interfaces/IOptionMarket.sol";
import "../interfaces/IOptionToken.sol";
import "../interfaces/IShortCollateral.sol";

contract TraderExample is Ownable {
    IOptionMarket public optionMarket;
    IOptionToken public optionToken;
    IShortCollateral public shortCollateral;

    // check "Deployment Addresses" for other markets  
    constructor( 
        IOptionMarket _ethMarketAddress, 
        IOptionToken _ethOptionToken,
        IShortCollateral _ethShortCollateral
    ) Ownable() {
        optionMarket = _ethMarketAddress; 
        optionToken = _ethOptionToken; 
        shortCollateral = _ethShortCollateral;
    }
}
```
Refer to [Deployment Addresses](tbd...sorry) to get addresses of different `base`/`quote` option markets. 

*We will assume that the current options market already has liquidity and active listings (refer to [Setup Environment](tbd...sorry) for more).*

## Open a new position

Lyra options are organized by `OptionMarket`, `boardId`, `listingId` and `positionId`:
* `OptionMarket` - contract/address that manages options for an underlying `base`/`quote` pair (e.g. ETH/USD)
* `boardId` - contains multiple listings sharing the same expiry
* `listingId` - signifies options with the same strike price ($1500 strike for the Feb 20th expiry board)
* `positionId` - single option position (a trader can open several positions per listingId)

Each position must choose an `optionType` - long/short; call/put; base/quote collateralized, specified by the following enum: 

```solidity
enum IOptionMarket.OptionType {
  LONG_CALL,
  LONG_PUT,
  SHORT_CALL_BASE, // base collateral
  SHORT_CALL_QUOTE, // quote collateral
  SHORT_PUT_QUOTE // quote collateral
}
```

When opening/adjusting a position, we need to consider 4 more params:

* `setCollateralTo` - for shorts, what collateral should be remaining for the position after the trade
* `minTotalCost/maxTotalCost` - boundaries for the `totalCost` (premium + slippage + fees) at trade execution (otherwise revert)
* `iterations` - number of sub orders to cut into (only relevant for very large orders). This helps optimize the black-scholes price for very large trades (refer to [appendix C](https://www.lyra.finance/files/whitepaper.pdf) of the whitepaper for more details). 

Let's sell 10x quote collateralized short contracts for the $1500 strike/Feb 25 listing.

```solidity
IOptionMarket.TradeInputParameters tradeParams = IOptionMarket.TradeInputParameters({
  listingId: 2, // refer to "Get_Market_Info" for querying listing/other market info
  positionId: 0, // leave as 0 for new positions
  iterations: 1,
  optionType: IOptionMarket.OptionType.SHORT_CALL_QUOTE,
  amount: 10,
  setCollateralTo: 10000, // @ $2500 ETH price, full collateral would be $25000
  minTotalCost: 0,
  maxTotalCost: type(uint).max,
}
```

>Note, depositing collateral >= full collateral guarantees no liquidations. 


```solidity
IOptionMarket.Result result = optionMarket.openPosition(tradeParams);
```

## Get existing position details

Notice, `openPosition` returned a `Result` struct, which contains useful trade execution details:

```solidity
struct IOptionMarket.Result {
    uint positionId; // id of opened position
    uint totalCost; // final execution cost (premium + slippage + fees)
    uint totalFee; // spot + option + vegaUtil fees
  }
```

>Stay tuned for more [LEAPs](https://leaps.lyra.finance/all-leap) on trading rewards for Avalon.

Using the `positionId` we can retreive all details for the position we just opened.

```solidity
IOptionToken.PositionWithOwner position = optionToken.getPositionWithOwner(positionId);
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

## Adjust position amount and collateral

Now, let's do a more complex trade
* close only 50% of the current position.amount
* add $1000 more collateral

We use the same `TradeInputParameters` struct but this time we call `closePosition` as we are reducing the position amount. Let's use the same `position` variable to fill in the static params.

```solidity
IOptionMarket.TradeInputParameters tradeParams = IOptionMarket.TradeInputParameters({
  listingId: position.listingId, // 
  positionId: position.positionId, // leave as 0 for new positions
  iterations: 1,
  optionType: position.optionType,
  amount: position.amount / 2, // closing 50%
  setCollateralTo: position.collateral + 1000, // increase collateral by $1000
  minTotalCost: 0,
  maxTotalCost: type(uint).max, // assume we are ok with any premium amount
}
```

```solidity
IOptionMarket.Result result = optionMarket.closePosition(tradeParams);
```

If we were to set `TradeInputParams.amount` = `position.amount`, the position would be fully closed and `position.state` would be set to `CLOSED`. This will send back all the position collateral for shorts regardless of the `setCollateralTo` input.

## Settle expired position

Once `block.timestamp` > the listing `expiry`, a keeper will call `OptionMarket.settleBoard` and allow for individual traders to settle their positions. 

Let's say we had opened two more options: (1) 1x LONG_CALL and (2) 1x SHORT_PUT_QUOTE with the `positionIds` (1) #2 and (2) #3. We can make the below call to send the option payouts to the `position.owner` address.

```solidity
uint[] settleAmounts = shortCollateral.settleOptions([1, 2, 3]); // closing all 3x positions
```

`settleAmounts` is returned, which specifies the total `base` or `quote` amounts sent to the `position.owner`.

> Note: You do not have to be the owner of a position to settle it. Any contract integrating with lyra should be able to handle settlement as having funds sent directly into the contract by someone else.

## Settle scenarios:

* LONG_CALL
  * `if spot > strike: amount * (spot - strike)` reserved per option to pay out to the user (in quote)
* LONG_PUT
  * `if spot < strike: amount * (strike - spot)` reserved per option to pay out to the user (in quote)
* SHORT_CALL_BASE
  * `if spot > strike: amount * (spot - strike)` paid to LP from `position.collateral` (automatically converted to quote)
  * remainder is sent to trader
* SHORT_CALL_QUOTE
  * `if spot > strike: amount * (spot - strike)` paid to LP from `position.collateral` (in quote)
  * remainder is sent to trader
* SHORT_PUT_QUOTE
  * `if spot < strike: amount * (strike - spot)` paid to LP from `position.collateral` (in quote)
  * remainder is sent to trader

## Revert scenarios

| error message                               | contract            | description                         |
| ------------------------------------------- | --------------------|------------------------------------ |
| total cost outside of specified bounds      | OptionMarket        | `totalCost` < minCost or > maxCost
| invalid trade type                          | OptionMarket        | `optionType` not in `OptionType` enum
| must have more than 0 iterations            | OptionMarket        | 
| board frozen                                | OptionMarket        | admin has frozen board
| board expired                               | OptionMarket        | listing `expiry` < `block.timestamp`
| cannot change collateral for long           | OptionMarket        | must set `collateral` to 0 for longs
| insufficient funds                          | ERC20               | LP or trader does not have sufficient funds
| vol too high/vol too low                    | OptionMarketPricer  | trade slipped vol, skew or IV beyond `IOptionMarketPricer.tradeLimitParams` limits
| delta out of range                          | OptionMarketPricer  | use `forceClose` to bypass
| trading cutoff range                        | OptionMarketPricer  | use `forceClose` to bypass
| minimum collateral not met                  | OptionToken         | new collateral < minimum required collateral
| adjusting position for non owner            | OptionToken         | `position.owner` must equal `msg.sender`
| position must be active in order to adjust  | OptionToken         | `position.state` must be `ACTIVE`
| invalid positionId/listingId/optionType     | OptionToken         | `TradeInputParameters` do no match `positionId`
| board must be settled                       | ShortCollateral     | `OptionMarket.settleBoard` has not been called
| SC out of base/quote funds                  | ShortCollateral     | system livelihood failure

## Force Closing (a.k.a Universal Closing)

In Avalon, traders can close options with very low and high deltas, as well as options that are very close to expiry.

The order flow/logic of `IOptionMarket.forceClose` and `IOptionMarket.liquidate` have two distinct features that differentiate them from `closePosition`.
* GWAV `skew`/`vol` are used to compute the black-scholes iv
* The AMM only applies slippage to the `skew` (and not `baseIv`)

*Refer to the Universal Closing section in [LEAP 18](https://leaps.lyra.finance/leaps/leap-18) for the mechanism relating to force close.*
