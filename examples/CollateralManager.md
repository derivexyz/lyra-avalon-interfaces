# Collateral Manager Example

Partially collateralized positions can go underwater as spot price and time to expiry change. In this example, we build an on-chain collateral manager to reduce risk of liquidations of multiple large options positions. If a portfolio contains 1x short call and 1x short put and ETH price goes increases from $3,000 -> $3500 we have an opportunity to rebalance collateral from short put -> short call without requiring any extra funds.

## Example Collateral Manager Contract

In this guide, we will create a contract that interact with the Lyra markets via the VaultAdapter.sol:
1. [Setup manager contract](#setup)
2. [Transfer positions to manager](#transfer)
3. [Keep track of open short positions](#track)
4. [Calculate minimum collateral](#mincollat)
5. [Gather excess collateral](#excess)
6. [Top off and close "risky" positions](#topoffAndClose)
7. [`closePosition` vs `forceClose`](#force)

## Set Up the Contract <a name="setup"></a>

In the [Trading](...) example, we imported/interacted directly with several different Lyra contracts. To greatly simplify integration, our manager contract can inherit the [VaultAdapter.sol]() which contains all the standard Lyra functions in one place.

Install the [@lyrafinance/protocol](https://www.npmjs.com/package/@lyrafinance/protocol) package and follow the setup instructions.

```solidity
pragma solidity 0.8.9;
import {VaultAdapter} from "@lyrafinance/protocol/contracts/periphery/VaultAdapter.sol";

// Libraries
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CollateralManagerExample is VaultAdapter, Ownable {
  constructor() VaultAdapter() Ownable();
    
  function initAdapter(
    address _curveSwap,
    address _optionToken,
    address _optionMarket,
    address _liquidityPool,
    address _shortCollateral,
    address _synthetixAdapter,
    address _optionPricer,
    address _greekCache,
    address _quoteAsset,
    address _baseAsset,
    address _feeCounter
  ) external onlyOwner {
    setLyraAddresses(
      _curveSwap,
      _optionToken,
      _optionMarket,
      _liquidityPool,
      _shortCollateral,
      _synthetixAdapter,
      _optionPricer,
      _greekCache,
      _quoteAsset,
      _baseAsset,
      _feeCounter
    );

    quoteAsset.approve(address(vault), type(uint).max);
    baseAsset.approve(address(vault), type(uint).max);
  }
}
```

Call `getMarketDeploys()/getGlobalDeploys()` via [@lyrafinance/protocol](https://www.npmjs.com/package/@lyrafinance/protocol) to get deployment addresses.

## Transfer position ownership to manager <a name="transfer"></a>

Assuming you already have open positions, we must first transfer ownership of these positions to the manager:

```typescript
import { getMarketDeploys } from '@lyrafinance/protocol';

let lyraMarket = getMarketDeploys('kovan-ovm', 'sETH');
const optionToken = new Contract(lyraMarket.OptionToken.address, lyraMarket.OptionToken.abi, deployer);

// may need to add your own routine (try/catch, gas limit, etc)
await optionToken["transferFrom"](deployer.address, collateralManagerAddress, positionId);
```

## Only track short positions  <a name="track"></a>

After transfering ownership, we record the positions in the manager contract. `VaultAdapter._getPositions()` can be used to get all position details. As we are inheriting `VaultAdapter` we can also use the built-in structs.

```solidity
uint[10] public trackedPositionIds; // setting hard 10x position limit
mapping(uint => OptionPosition) public trackedPositions;
uint public positionHead = 0;

function trackPositions(uint[] positionIds) external onlyOwner {
  require(positionHead + positionIds.length <= trackedPositions.length, 
    "exceeded max # of tracked positions");
      
  OptionPosition[positionIds.length] positions = _getPositions(positionIds);
      
  for (uint i = 0; i < positionIds.length; i++) {
    // screen out long positions
    if (positions[i].state == PositionState.ACTIVE 
      && positions[i].optionType != OptionType.LONG_CALL 
      && positions[i].optionType != OptionType.LONG_PUT
    ) {
      trackedPositionIds[positionHead] = positionIds[i];
      trackedPositions[positionIds[i]] = positions[i];
      positionHead++
    }
  }
}
```

*For brevity, we skip over functions that allow manual removal of positions.*

## Calculate minimum collateral <a name="mincollat"></a>

To decide whether we want to topOff or take excess collateral from a position, we calculate the `minCollateral` using `VaultAdapter._getMinCollateralForPosition()` and add a 50% buffer. The direct alternative to this is `OptionGreekCache.getMinCollateral()` but requires more cross-contract calls.

```solidity
function _getTargetCollateral(uint positionId)
  internal returns (uint targetCollateral) {
  targetCollateral = _getMinCollateralForPosition(positionId).multiplyDecimal(50 * 1e16);
}
```

If we wanted to determine estimate the `minCollatateral` if price jumped 50% we could use `VaultAdapter._getMinCollateral()` which takes in manual params such as `spotPrice`, `expiry`.

## Gather excess collateral and flag "risky" positions  <a name="excess"></a>

Now that we can calculate the `targetCollateral` for each position, we can gather collateral from excess positions and flag positions below our target collateral. We create `flaggedPositionIds` and `neededCollat` arrays to keep track of "risky" positions and `gatheredCollat` to track total funds held by the manager.

```solidity
uint[] flaggedPositionIds;
mapping(uint => uint) neededCollat;
uint gatheredCollat;

function gatherAndFlag() 
  external {
  delete flaggedPositionIds; // clear out outdated flags/collateral

  TradeInputParameters tradeParams;
  for (uint i; i < positionHead; i++) {
    OptionPosition currentPosition = trackedPositions[trackedPositionIds[i]];
    uint currentCollat = currentPosition.collateral;
    uint targetCollat = _getTargetCollateral(trackedPositionIds[i]);
        
    if (currentCollat > targetCollat) { // if there is excess collateral
      tradeParams = TradeInputParameters({
        strikeId: currentPosition.strikeId,
        positionId: currentPosition.positionId,
        iterations: 1, // no need to optimize iterations as amount does not change
        optionType: currentPosition.optionType,
        amount: 0,
        setCollateralTo: targetCollat, // returns any excess collateral
        minTotalCost: 0,
        maxTotalCost: type(uint).max
      });
      _openPosition(tradeParams); // using _closePosition() would have the same effect
      gatheredCollat += currentCollat - targetCollat;

      // update position records
      trackedPositions[trackedPositionIds[i]] = _getPositions([trackedPositionIds[i]])[0];
    } else { // if collateral below target, flag position
      neededCollat[trackedPositionIds[i]] = targetCollateral - currentCollat;
      flaggedPositionIds.push(trackedPositionIds[i]);
    }
  }
}
```

To change collateral we can use `VaultAdapter._openPosition()`. Setting the `setCollateralTo` param to `targetCollat` returns any excess collateral to `msg.sender`.

*To avoid dealing with ETH/USD conversions, we assume the portfolio only uses quote collateral.*

## Topoff or close "risky" positions  <a name="topoffAndClose"></a>

We can topoff positions the same way we gathered excess collateral. If our manager runs out of funds, the contract reverts to simply closing the position. 

```solidity
function topoffOrClose() external {
  OptionPosition currentPosition;
  TradeInputParameters tradeParams;
  for (uint i; i < flaggedPositionIds.length; i++) {
    currentPosition = trackedPositions[flaggedPositionIds[i]];
    tradeParams = TradeInputParameters({
      strikeId: currentPosition.strikeId,
      positionId: currentPosition.positionId,
      iterations: 1,
      optionType: currentPosition.optionType,
      amount: 0,
      setCollateralTo: _getTargetCollateral(currentPosition.positionId),
      minTotalCost: 0,
      maxTotalCost: type(uint).max
    });

    if (gatheredCollat >= neededCollat[i]) {
      _openPosition(tradeParams);
      gatheredCollat -= neededCollat[i];
    } else { // fully close position if not enough collateral
      tradeParams.setCollateral = 0;
      tradeParams.amount = currentPosition.amount; 

      if (_needsForceClose(OptionPosition position)) {
        _forceClosePosition(tradeParams);
      } else {
        _closePosition(tradeParams);
      }   
    }
    neededCollat[i] = 0;
  }
  delete flaggedPositionIds;
}
```

## Decide between closePosition and forceClose <a name="force"></a>

When closing positions in the above function, we had to determine whether we need to use `closePosition` and `forceClose` as sometimes positions may be outside of the delta cutoff range or too close to expiry. We can use several built-in `VaultAdapter` functions to make this decision.

```solidity
function _needsForceClose(OptionPosition position) internal {
  // get position delta, expiry, current time
  uint callDelta = _getDeltas([position.strikeId])[0]; // we assume we are selling calls for simplicity
  uint timeToExpiry = (_getStrikes([position.strikeId])[0]).expiry - block.timestamp;

  // compare with market params
  MarketParams marketParams = _getMarketParams();
  return (
    timeToExpiry < marketParams.tradingCutoff 
    || callDelta < deltaCutOff 
    || callDelta > (DecimalMath.UNIT - deltaCutOff))
}
```