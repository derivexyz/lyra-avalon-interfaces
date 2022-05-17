There are 3x methods to interact with Lyra markets on-chain:
1. OptionMarketWrapper.sol - open/close/forceClose via wrapper with automatic trading rewards/non-sUSD stable support
2. VaultAdapter.sol - all vault related functions via single inherited contract
3. Core contracts (OptionMarket.sol/ShortCollateral.sol) - interact with multiple contracts but get max control

See example guides to learn how to use each method.