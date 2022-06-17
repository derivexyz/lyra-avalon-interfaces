## Overview

There are 3x methods to interact with Lyra markets on-chain:
1. OptionMarketWrapper.sol - open/close/forceClose via wrapper with automatic trading rewards (optimized for lyra-js SDK)
2. VaultAdapter.sol - all vault related functions via single inherited contract (for on-chain)
3. Core contracts (OptionMarket.sol/ShortCollateral.sol) - more complex setup but max control

See example guides to learn how to use each method.

## Trading Rewards

For off-chain trading, it is recommended to use the `OptionMarketWrapper.sol` as rewards are automatically accrued to the trader

For on-chain trading, it is recommended to inherit the `LyraAdapter.sol` and request whitelisting via the Lyra Discord. 

The whitelisting process will be prompt as long as:
- The parent contract is not upgradeable
- The `_open/close/closeOrForceClosePosition()` functions are not modified