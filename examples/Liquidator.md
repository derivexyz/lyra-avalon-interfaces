# Liquidator Example

Partial collateralization of short options allows traders to earn premiums with leverage while giving liquidators an opportunity to earn fees by liquidating underwater positions.

In this guide, we setup a simple contract that liquidates multiple underwater positions:
- [x] Basics
- [x] Setup
- [x] Liquidating multiple positions
- [x] Revert scenarios
- [x] Liquidation profitability calculation
- [x] Under-collateralized positions


>Refer to the [CollateralManager example](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/examples/CollateralManager.md) on how to check minimum collateral and create a collateral manager contract. For more information on the mechanism behind liquidations, refer to [LEAP 18](https://github.com/lyra-finance/LEAPs/blob/main/content/leaps/leap-18.md).


## Basics
Anyone can liquidate a position using the `liquidatePosition` function in the [IOptionMarket](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionMarket.sol) contract, as long as the position is active and underwater. The only two required inputs are `positionId` and `rewardBeneficiary`. The liquidator requires no funds to execute a liquidation other than ETH to pay for gas fees.

>Refer to the [Liquidation Bot](tbd...sorry) guide to learn how to track all active positionIds off-chain using events. In this guide we will assume you already have a list of underwater positions.

## Setup the contract
As an example, let's setup a simple contract that connects to the ETH/USD options market through the [IOptionMarket](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionMarket.sol) interface. Refer to the [Deployment Addresses](tbd...sorry) section for other markets. 

```solidity
pragma solidity 0.8.9;
import "../interfaces/IOptionMarket.sol";

contract LiquidatorExample {
    IOptionMarket public optionMarket; // ETH/USD options market address
    internal address rewardBeneficiary; // address to deposit liquidation fees

    constructor(IOptionMarket _optionMarket, address rewardBeneficiary) {
        optionMarket = _optionMarket;
        rewardBeneficiary = _rewardBeneficiary;
    }
}    
```

[IOptionMarket](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionMarket.sol) will deposit your liquidation fees to the `rewardBeneficiary` address.

## Liquidating multiple positions

Now include a simple wrapper function that liquidates multiple positions which you have identified off-chain:
```solidity
function liquidateMultiplePositions(uint[] positionIds) external {
    for (uint i = 0; i < positionIds.length; i++) {
        optionMarket.liquidatePosition(positionIds[i], rewardBeneficiary);
    }
} 
```
Upon successful liquidation, each position will pay out the liquidation fee in the collateral currency. So liquidation of an sETH collateralized short call will send sETH to `rewardBeneficiary`, while liquidation of an sUSD collateralized short call will denominate the fee in sUSD.

## Revert scenarios
| error message                        | description                          |
| ---------------------------- | ------------------------------------ |
| "position not liquidatable"  | not a short position, is inactive, or collateral > minCollateral  |

## Liquidation profitability calculation

When a position is liquidated, a penalized premium is charged to the liquidated user and remaining collateral is split between the user, liquidator, LPs and security module. These parameters are set in the `partialCollatParams` struct in the [OptionToken](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/contracts/interfaces/IOptionToken.sol) contract. 

Here is a mock calculation of the liquidation fee for a quote collateralized short call given known user collateral and penalized premium.

```solidity
IOptionToken.OptionPosition position = IOptionToken.OptionPosition({ 
    positionId: 123, 
    listingId: 2
    optionType: IOptionToken.OptionType.SHORT_CALL_QUOTE, 
    amount:1
    collateral: 1000, 
    state: IOptionToken.PositionState.ACTIVE
}); // mock option position
uint penalizedPremium = 1000; // mock penalizedPremium
IOptionToken.PartialCollateralParameters params = optionToken.partialCollatParams();

uint remainingCollateral = 
        (position.collateral - penalizedPremium); // see "insolvency" if underwater

uint liquidationFee;
if (remainingCollateral > params.minliquidationFee) { // denominated in quote
    liquidationFee = remainingCollateral
        .multiplyDecimal(params.liquidatorFeeRatio)
        .multiplyDecimal(params.penaltyRatio);
} else {
    liquidationFee = params.minliquidationFee * params.liquidatorFeeRatio;
}
```
For simplicity, the above example does not account for ETH collateralized shorts. In reality, `remainingCollateral` would need to be converted to USD first before entering the `if` statement.

> To ensure profitable liquidations of small positions, Lyra enforces a minimum USD denominated `minLiquidationFee` that is > gas fee.

## Under-collateralized positions

In extreme conditions (e.g. Optimism goes down for an extended time), positions could become under-collateralized and remainingCollateral == 0. To ensure that even these can be liquidated profitably, the liquidationFee is deducted from the penalizedPremium and paid to the liquidator.