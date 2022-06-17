## Overview

There are 3x methods to interact with Lyra markets:
1. JS SDK - routes orders through OptionMarketWrapper.sol and automatically accrues trading rewards
2. LyraAdapter.sol - all market related functions via single inherited contract
3. Core contracts - more complex setup but max control

See example guides to learn how to use each method.

## Trading Rewards

For off-chain trading, it is recommended to use the lyra-js SDK, which will use `OptionMarketWrapper.sol` under-the-hood as rewards are automatically accrued to the trader.

For on-chain trading, it is recommended to inherit the `LyraAdapter.sol` and request whitelisting via the Lyra Discord. 

The whitelisting process will be prompt as long as:
- The parent contract is not upgradeable
- The `_open/close/closeOrForceClosePosition()` functions are not modified