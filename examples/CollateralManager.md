# Collateral Manager Example

Partially collateralized positions can go underwater as spot price and time to expiry change. Protocols and traders with multiple large options positions may require an on-chain collateral manager contract to reduce risk of liquidations.

## Example Collateral Manager Contract

If a portfolio contains 1x short call and 1x short put and ETH price goes increases from $3,000 -> $3500 we have an opportunity to rebalance collateral from short put -> short call without require any extra funds.  
Here are the goals for our contract:

- [x] Use funds from positions with excess collateral to top off risky positions
- [x] Close out risky positions if there are no positions to pull funds from

## Set Up the Contract

First, let's connect our contract to [IOptionMarket](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionMarket.sol), [IOptionGreekCache](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionGreekCache.sol), [IOptionToken](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionToken.sol) and [ISynthetixAdapter](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/SynthetixAdapter.sol), all of which are provided as part of the integrations repo.

As in the [LiquidatorExample](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/examples/Liquidator.md), the contract will be tailored for the ETH/USD market.

```solidity
pragma solidity 0.8.9;
import "../interfaces/IOptionMarket.sol";
import "../interfaces/IOptionGreekCache.sol";
import "../interfaces/IOptionToken.sol";
import "../interfaces/ISynthetixAdapter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CollateralManagerExample is Ownable {
    IOptionMarket public optionMarket;
    IOptionGreekCache public greekCache;
    IOptionToken public optionToken;
    ISynthetixAdapter public synthetixAdapter;
    
    // check "Deployment Addresses" for other markets  
    constructor( 
        IOptionMarket _ethMarketAddress, 
        IOptionGreekCache _ethGreekCache,
        IOptionToken _ethOptionToken,
        ISynthetixAdapter _synthetixAdapter
    ) Ownable() {
        optionMarket = _ethMarketAddress; 
        greekCache = _ethGreekCache; 
        optionToken = _ethOptionToken; 
        synthetixAdapter =  _synthetixAdapter;
    }
}
```

## Transfer position ownership to manager

In order to allow the manager to add/remove collateral and close positions, we must first transfer ownership of these positions.  This is easiest done outside of the contract by the owner:

```solidity
uint positionId = 123; // owned by msg.sender
IOptionToken optionToken = IOptionToken(_optionToken); // see "Deployment Addresses"
optionToken.transferFrom(msg.sender, collateralManagerAddress, positionId)
```

If you only need to add collateral, you can use the `addCollateral` function in the [IOptionMarket](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionMarket.sol) without needing to transfer positions.

## Add tracked positions

After transfering ownership, we must let the manager know which positions to track. For simplicity, our contract will set a 10x position limit. We bulk store tracked positions into the `trackedPositions` mapping using `getOptionPositions` in [IOptionToken](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionToken.sol). 

```solidity
uint[10] public trackedPositionIds; // setting hard 10x position limit
mapping(uint => IOptionToken.PositionAndOwner) public trackedPositions;
uint public positionHead = 0;

function trackPositions(uint[] positionIds) external onlyOwner {
    require(positionHead + positionIds.length <= trackedPositions.length, 
        "exceeded max # of tracked positions");
        
    IOptionToken.PositionAndOwner[positionIds.length] positionAndOwners = 
        optionToken.getOptionPositions(positionIds);
        
    for (uint i = 0; i < positionIds.length; i++) {
        trackedPositionIds[positionHead] = positionIds[i];
        trackedPositions[positionIds[i]] = positionAndOwners[i];
        positionHead++;
    }
}
```

*Note, for brevity, we skip over functions that filter out inactive positions or manual removal of positions.*

## Calculate minimum collateral

Now, we create the core functions that calculate the minimum required collateral if spot price moves 30%. The `getMinCollateral` function in [IOptionGreekCache](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionGreekCache.sol) can be used to calculate minimum collateral for a given strike, expiry, spotPrice and position amount. 

For our use case, we will copy over all this information from the `OptionPosition` struct, except for the `spotPrice` - which we will increase/decrease by 30% depending on whether it is a call or a put. 
To get the current spot price of sETH we use the [ISynthetixAdapter](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/SynthetixAdapter.sol) contract.

```solidity
uint public spotBufferPercentage = (30 * 1e16) // 30% buffer

function _getBufferSpot(IOptionToken.OptionPosition position) {
    internal returns (uint bufferSpot) {
    uint spot = synthetixAdapter.getSpotPriceForMarket(address(optionMarket));
    bufferSpot = 
        position.optionType == IOptionMarket.OptionType.SHORT_PUT_QUOTE
        ? spot.multiplyDecimal(DecimalMath.UNIT - spotBufferPercentage);
        : spot.multiplyDecimal(DecimalMath.UNIT + spotBufferPercentage);
}
```

Next, we can create our `_getTargetCollateral` function. Notice, if we were to input the spot price instead of bufferSpot, `getMinCollateral` would return the price at which the position would get liquidated. 

```solidity
function _getTargetCollateral(
    IOptionToken.PositionAndOwner positionAndOwner, 
    uint bufferSpot)
    internal returns (uint targetCollateral) { // assumes only quote collateral
    (uint strike, uint expiry) = 
        optionMarket.getListingStrikeExpiry(positionAndOwner.listingId);
    uint targetCollateral = optionGreekCache.getMinCollateral(
        positionAndOwner.optionType, 
        strike, 
        expiry, 
        bufferSpot, 
        positionAndOwner.amount;
}
```

> `getMinCollateral` always denominates the return in the collateral currency.

## Gather excess collateral and flag "risky" positions

Now that we can calculate the target collateral for each position, we can gather collateral from excess positions and flag positions below our target collateral. We create `flaggedPositionIds` and `neededCollat` arrays to keep track of "risky" positions and `gatheredCollat` to track total funds held by the manager.

```solidity
uint[] flaggedPositionIds;
uint[] neededCollat;
uint gatheredCollat;

function gatherAndFlag() 
    external {
    delete flaggedPositionIds; // clear out outdated flags/collateral
    delete neededCollat;
    
    mapping(uint => uint) memory neededCollat = 0;
    IOptionToken.PositionAndOwner[positionHead] positionAndOwners = 
        optionToken.getOptionPositions(trackedPositionIds[:positionHead]);

    for (uint i; i < positionHead; i++) {
        uint currentCollat = positionAndOwners[i].collateral;
        uint bufferSpot = _getBufferSpot(positionAndOwner.position);
        uint targetCollat = _getTargetCollateral(positionAndOwners[i], bufferSpot);
            
        if (currentCollat > targetCollat) {
            gatheredCollat += currentCollat - targetCollat;
            optionMarket.openPosition(
                positionAndOwners[i].positionId,
                1, 
                positionAndOwners[i].optionType,
                0, // no additional amount is purchased
                targetCollat, // returns any excess collateral
                0, 0);
        } else {
            flaggedPositionIds.push(trackedPositionIds[i]);
            neededCollateral.push(targetCollateral - collateral);
        }
    }
}
```

To gather extra collateral we call openPosition in [IOptionMarket](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionMarket.sol) (refer to Open and Close for more details). 

> Notice, by setting the `setCollateralTo` param in `openPosition`, we can gather excess collateral.

*Note, to avoid dealing with ETH/USD conversions, we assume the portfolio only uses quote collateral.*

## Topoff or close "risky" positions

We can topoff positions the same way we gathered excess collateral. If our manager runs out of funds, the contract reverts to simply closing the position. 

```solidity
function topoffOrClose() external {
    IOptionToken.PositionAndOwner currentPosition;
    for (uint i; i < flaggedPositionIds.length; i++) {
        currentPosition = trackedPositions[flaggedPositionIds[i]];
        if (gatheredCollat >= neededCollat[i]) {
            optionMarket.openPosition(
                currentPosition.positionId,
                1, 
                currentPosition.optionType,
                0, // no additional amount is purchased
                targetCollat, // returns any excess collateral
                0, 0);
            gatheredCollat -= gatheredCollat - neededCollat[i];
        } else {
            optionMarket.closePosition(
                currentPosition.positionId,
                1, 
                currentPosition.optionType,
                currentPosition.amount, // close out full amount
                0, // set collateral to 0
                0, type(uint).max); // assume we are ok with any closing price
        }
    }
    delete neededCollat;
    delete flaggedPositionIds;
}
```

The `forceClose` function in [IOptionMarket](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionMarket.sol) can be used to close out options outside of normal delta/time cutoffs.