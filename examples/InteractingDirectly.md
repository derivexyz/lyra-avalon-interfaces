# Interacting Directly w/Lyra

In this guide, we will open trades directly via the core Lyra contracts.

*Note: In most cases, the simplest method to interacting with Lyra on-chain is via the LyraAdapter.sol. For a more detailed example of interacting with Lyra via `LyraAdapter.sol` refer to: [trading](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/examples/Trading.md)*

## Setup simple trader contract
Install the [@lyrafinance/protocol](https://www.npmjs.com/package/@lyrafinance/protocol) package and follow the setup instructions.

Import [OptionMarket.sol](https://github.com/lyra-finance/lyra-protocol/blob/master/contracts/OptionMarket.sol), [OptionToken.sol](https://github.com/lyra-finance/lyra-protocol/blob/master/contracts/OptionToken.sol) and [ShortCollateral.sol](https://github.com/lyra-finance/lyra-protocol/blob/master/contracts/ShortCollateral.sol). 

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

      quoteAsset.approve(address(optionMarket), type(uint).max);
      baseAsset.approve(address(optionMarket), type(uint).max);
    }
}
```
Call `getMarketDeploys` via [@lyrafinance/protocol](https://www.npmjs.com/package/@lyrafinance/protocol) to get addresses of different `base`/`quote` option markets.

## Open a new position

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

## Trading Rewards

To get trading rewards, refer to [Overview](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/examples/Intro.md)