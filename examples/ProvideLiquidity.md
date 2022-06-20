# Provide Liquidity

Liquidity to buy/sell option on the Lyra market is provided by LPs who commit their funds to an on-chain AMM. In this guide, we will deposit/withdraw liquidity on-chain, as well as get other relevant info about the state of the AMMs liquidity. 

1. [Setup](#setup)
2. [Deposit](#deposit)
3. [Withdraw](#withdraw)
4. [Getting reason for failed process](#failed)
5. [Liquidity value](#value)

## Setup <a name="setup"></a>

LP related activities can be performed directly with the `LiquidityPool.sol` core contract. As in the [Trading example](https://github.com/lyra-finance/lyra-avalon-interfaces/blob/master/examples/Trading.md), install the [@lyrafinance/protocol](https://www.npmjs.com/package/@lyrafinance/protocol) package and follow the setup instructions.

```solidity
pragma solidity 0.8.9;
import {LiquidityPool} from "@lyrafinance/protocol/contracts/LiquidityPool.sol";
```

Use the `@lyrafinance/protocol` SDK to get the latest kovan/mainnet address. Note, you can use both the `@lyrafinance/protocol` or `@lyrafinance/lyra-js` to perform all of the actions in this guide off-chain.

```typescript
import { getMarketDeploys } from '@lyrafinance/protocol';

// get lyra address/abi/bytecode/more
const lyraMarket = await getMarketDeploys('kovan-ovm', 'sETH');
const LiquidityPoolAddress = lyraMarket.liquidityPool.address;
```

## Deposit <a name="deposit"></a>

```solidity
// initiate a deposit for ADDRESS with amountQuote sUSD
liquidityPool.initiateDeposit(ADDRESS, amountQuote);
```

The below event will be emitted, which can be used to get the deposit's place in the queue:
```solidity
event DepositQueued(
    address indexed depositor,
    address indexed beneficiary,
    uint indexed depositQueueId, // place in the queue
    uint amountDeposited,
    uint totalQueuedDeposits,
    uint timestamp
);

// to get all deposit request details
liquidityPool.QueuedDeposit queuedDeposit = liquidityPool.queuedDeposits(depositQueueId);
```

Now, `processDepositQueue` must be called successfully to mint LiquidityTokens to the ADDRESS. This function will be run periodically via lyra bots but can also be called by anyone. 

```solidity
// attempt deposit process on 5 queued deposits
liquidityPool.processDepositQueue(5);

// emitted event on successful process
event DepositProcessed(
  address indexed caller,
  address indexed beneficiary,
  uint indexed depositQueueId,
  uint amountDeposited, // sUSD
  uint tokenPrice, // sUSD per LiquidityToken
  uint tokensReceived, // LiquidityTokens minted
  uint timestamp
);
```

## Withdraw <a name="withdraw"></a>

```solidity
// initiate a withdraw for ADDRESS for amountTokens of LiquidityTokens
liquidityPool.initiateWithdraw(ADDRESS, amountTokens);
```

The below event will be emitted, which can be used to get the withdraw request's place in the queue:
```solidity
event WithdrawQueued(
  address indexed withdrawer,
  address indexed beneficiary,
  uint indexed withdrawalQueueId, // place in the queue
  uint amountWithdrawn,
  uint totalQueuedWithdrawals,
  uint timestamp
);

// to get all withdrawal request details
liquidityPool.QueuedWithdrawal queuedWithdrawal = liquidityPool.queuedWithdrawals(withdrawalQueueId);
```

As in deposits, `processWithdrawalQueue` must be called successfully to return sUSD to the ADDRESS.

```solidity
// attempt withdraw process on 5 queued withdrawals
liquidityPool.processWithdrawalQueue(5);

In contract with deposits, withdrawals can be partially processed if liquidity is constrained:
event WithdrawProcessed or WithdrawPartiallyProcessed (
  address indexed caller,
  address indexed beneficiary,
  uint indexed withdrawalQueueId,
  uint amountWithdrawn,
  uint tokenPrice,
  uint quoteReceived,
  uint totalQueuedWithdrawals,
  uint timestamp
);

// to get remaining token amount that has not been processed
liquidityPool.QueuedWithdrawal queuedWithdrawal = liquidityPool.queuedWithdrawals(withdrawalQueueId);
uint remainingTokens = queuedWithdrawal.amountTokens;
```

## Getting reason for failed process <a name="failed"></a>

Deposit and Withdrawal processes can fail due to the below reasons. Refer to ??? for more:
1. Minimum deposit/withdrawal delay has not expired (currently set to 7 days)
2. Circuit Breaker triggered due to market volatility
3. Circuit Breaker triggered due to low liquidity
4. Circuit Brekaer triggered due to board settlement
5. `updateBoardCachedGreeks` has not been called in a long time (usually automatically called by lyra bots)

To get the exact reason for a specific failed process, retreive the `CheckingCanProcess` event emitted during a `processDeposit/WithdrawalQueue` tx:
```solidity
CheckingCanProcess(
  uint entryId,  // deposit or withdrawal queue id
  bool boardNotStale, // reason #5
  bool validEntry, 
  bool guardianBypass, 
  bool delaysExpired // reasons #1-4
); 

// To get the exact time at which the Circuit Breaker will turn back off:
uint whenCBExpires = liquidityPool.CBTimestamp();
```

## Liquidity value <a name="value"></a>

Once a deposit is processed, you can check the value of your LiquidityTokens:
```solidity
import {LiquidityToken} from "@lyrafinance/protocol/contracts/LiquidityPool.sol";

function getTokenValue() {
  uint tokenAmount = liquidityToken.balanceOf(address(this));
  (uint tokenValue, bool isStale, uint circuitBreakerExpiry) = liquidityPool.getTokenPriceWithCheck();

  // ensure valid conditions to get token value:
  if (!isStale && circuitBreakerExpiry < block.timestamp) {
    return tokenValue.multiplyDecimal(tokenAmount);
  } else {
    revert("token value is inaccurate due to market conditions"); 
  }
}
```
