//SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "hardhat/console.sol";

// Libraries
import "./synthetix/DecimalMath.sol";

// Inherited
import "@openzeppelin/contracts/access/Ownable.sol";

// Interfaces
import "./synthetix/interfaces/ISynthetix.sol";
import "./synthetix/interfaces/ICollateralShort.sol";
import "./synthetix/interfaces/IAddressResolver.sol";
import "./synthetix/interfaces/IExchanger.sol";
import "./synthetix/interfaces/IExchangeRates.sol";
import "./synthetix/interfaces/IDelegateApprovals.sol";

/**
 * @title SynthetixAdapter
 * @author Lyra
 * @dev Manages variables across all OptionMarkets, along with managing access to Synthetix.
 * Groups access to variables needed during a trade to reduce the gas costs associated with repetitive
 * inter-contract calls.
 * The OptionMarket contract address is used as the key to access the variables for the market.
 */
contract SynthetixAdapter is Ownable {
  using DecimalMath for uint;

  /**
   * @dev Structs to help reduce the number of calls between other contracts and this one
   * Grouped in usage for a particular contract/use case
   */
  struct ExchangeParams {
    uint spotPrice;
    bytes32 quoteKey;
    bytes32 baseKey;
    ICollateralShort short;
    uint quoteBaseFeeRate;
    uint baseQuoteFeeRate;
  }

  /// @dev Pause the whole system. Note; this will not pause settling previously expired options.
  mapping(address => bool) public isMarketPaused;
  bool public isGlobalPaused;

  IAddressResolver public addressResolver;

  // TODO: double check these are all the correct values
  bytes32 private constant CONTRACT_SYNTHETIX = "Synthetix";
  bytes32 private constant CONTRACT_EXCHANGER = "Exchanger";
  bytes32 private constant CONTRACT_EXCHANGE_RATES = "ExchangeRates";
  bytes32 private constant CONTRACT_COLLATERAL_SHORT = "CollateralShort";
  bytes32 private constant CONTRACT_DELEGATE_APPROVALS = "DelegateApprovals";

  // Cached addresses that can be updated via a public function
  ISynthetix public synthetix;
  IExchanger public exchanger;
  IExchangeRates public exchangeRates;
  ICollateralShort public collateralShort;
  IDelegateApprovals public delegateApprovals;

  // Variables related to calculating premium/fees
  mapping(address => bytes32) public quoteKey;
  mapping(address => bytes32) public baseKey;
  mapping(address => address) public rewardAddress;
  mapping(address => bytes32) public trackingCode;

  constructor() Ownable() {}

  /////////////
  // Setters //
  /////////////

  /**
   * @dev Set the address of the Synthetix address resolver.
   *
   * @param _addressResolver The address of Synthetix's AddressResolver.
   */
  function setAddressResolver(IAddressResolver _addressResolver) external onlyOwner {
    addressResolver = _addressResolver;
    updateSynthetixAddresses();
    emit AddressResolverSet(addressResolver);
  }

  /**
   * @dev Set the synthetixAdapter for a specific OptionMarket.
   *
   * @param _contractAddress The address of the OptionMarket.
   * @param _quoteKey The key of the quoteAsset.
   * @param _baseKey The key of the baseAsset.
   */
  function setGlobalsForContract(
    address _contractAddress,
    bytes32 _quoteKey,
    bytes32 _baseKey,
    address _rewardAddress,
    bytes32 _trackingCode
  ) external onlyOwner {
    quoteKey[_contractAddress] = _quoteKey;
    baseKey[_contractAddress] = _baseKey;
    rewardAddress[_contractAddress] = _rewardAddress;
    trackingCode[_contractAddress] = _trackingCode;
  }

  /**
   * @dev Pauses the contract.
   *
   * @param _isPaused Whether getting synthetixAdapter will revert or not.
   */
  function setMarketPaused(address _contractAddress, bool _isPaused) external onlyOwner {
    isMarketPaused[_contractAddress] = _isPaused;
    emit MarketPaused(_contractAddress, _isPaused);
  }

  function setGlobalPaused(bool _isPaused) external onlyOwner {
    isGlobalPaused = _isPaused;
    emit GlobalPaused(_isPaused);
  }

  //////////////////////
  // Address Resolver //
  //////////////////////

  /**
   * @dev Public function to update synthetix addresses Lyra uses. The addresses are cached this way for gas efficiency.
   */
  function updateSynthetixAddresses() public {
    synthetix = ISynthetix(addressResolver.getAddress(CONTRACT_SYNTHETIX));
    exchanger = IExchanger(addressResolver.getAddress(CONTRACT_EXCHANGER));
    exchangeRates = IExchangeRates(addressResolver.getAddress(CONTRACT_EXCHANGE_RATES));
    collateralShort = ICollateralShort(addressResolver.getAddress(CONTRACT_COLLATERAL_SHORT));
    delegateApprovals = IDelegateApprovals(addressResolver.getAddress(CONTRACT_DELEGATE_APPROVALS));

    emit SynthetixAddressesUpdated(synthetix, exchanger, exchangeRates, collateralShort, delegateApprovals);
  }

  /////////////
  // Getters //
  /////////////
  /**
   * @notice Returns the price of the baseAsset.
   *
   * @param _contractAddress The address of the OptionMarket.
   */
  function getSpotPriceForMarket(address _contractAddress) public view notPaused(_contractAddress) returns (uint) {
    return getSpotPrice(baseKey[_contractAddress]);
  }

  /**
   * @notice Gets spot price of an asset.
   * @dev All rates are denominated in terms of sUSD,
   * so the price of sUSD is always $1.00, and is never stale.
   *
   * @param to The key of the synthetic asset.
   */
  function getSpotPrice(bytes32 to) public view returns (uint) {
    (uint rate, bool invalid) = exchangeRates.rateAndInvalid(to);
    require(!invalid && rate != 0, "rate is invalid");
    return rate;
  }

  /**
   * @notice Returns the ExchangeParams.
   *
   * @param _contractAddress The address of the OptionMarket.
   */
  function getExchangeParams(address _contractAddress)
    public
    view
    notPaused(_contractAddress)
    returns (ExchangeParams memory exchangeParams)
  {
    exchangeParams = ExchangeParams({
      spotPrice: 0,
      quoteKey: quoteKey[_contractAddress],
      baseKey: baseKey[_contractAddress],
      short: collateralShort,
      quoteBaseFeeRate: 0,
      baseQuoteFeeRate: 0
    });

    exchangeParams.spotPrice = getSpotPrice(exchangeParams.baseKey);
    exchangeParams.quoteBaseFeeRate = exchanger.feeRateForExchange(exchangeParams.quoteKey, exchangeParams.baseKey);
    exchangeParams.baseQuoteFeeRate = exchanger.feeRateForExchange(exchangeParams.baseKey, exchangeParams.quoteKey);
  }

  //////////////
  // Swapping //
  //////////////

  function exchangeForExactBaseWithLimit(
    ExchangeParams memory exchangeParams,
    address optionMarket,
    uint amountBase,
    uint quoteLimit
  ) external returns (uint received) {
    uint quoteToSpend = amountBase
      .divideDecimalRound(DecimalMath.UNIT - exchangeParams.quoteBaseFeeRate)
      .multiplyDecimalRound(exchangeParams.spotPrice);

    require(quoteToSpend < quoteLimit, "Not enough free quote to exchange");

    return _exchangeQuoteForBase(msg.sender, optionMarket, quoteToSpend);
  }

  function exchangeForExactBase(
    ExchangeParams memory exchangeParams,
    address optionMarket,
    uint amountBase
  ) public returns (uint received) {
    uint quoteToSpend = amountBase
      .divideDecimalRound(DecimalMath.UNIT - exchangeParams.quoteBaseFeeRate)
      .multiplyDecimalRound(exchangeParams.spotPrice);

    return _exchangeQuoteForBase(msg.sender, optionMarket, quoteToSpend);
  }

  function exchangeFromExactQuote(address optionMarket, uint amountQuote) public returns (uint received) {
    return _exchangeQuoteForBase(msg.sender, optionMarket, amountQuote);
  }

  function _exchangeQuoteForBase(
    address sender,
    address optionMarket,
    uint amountQuote
  ) internal returns (uint received) {
    if (amountQuote == 0) {
      return 0;
    }
    received = synthetix.exchangeOnBehalfWithTracking(
      sender,
      quoteKey[optionMarket],
      amountQuote,
      baseKey[optionMarket],
      rewardAddress[optionMarket],
      trackingCode[optionMarket]
    );
    if (amountQuote > 1e10) {
      require(received > 0, "Received 0 from exchange");
    }
    emit QuoteSwappedForBase(optionMarket, sender, amountQuote, received);
  }

  function exchangeFromExactBase(address optionMarket, uint amountBase) external returns (uint received) {
    if (amountBase == 0) {
      return 0;
    }
    // swap exactly `amountBase` baseAsset for quoteAsset
    received = synthetix.exchangeOnBehalfWithTracking(
      msg.sender,
      baseKey[optionMarket],
      amountBase,
      quoteKey[optionMarket],
      rewardAddress[optionMarket],
      trackingCode[optionMarket]
    );
    if (amountBase > 1e10) {
      require(received > 0, "Received 0 from exchange");
    }
    emit BaseSwappedForQuote(optionMarket, msg.sender, amountBase, received);
  }

  ///////////////
  // Modifiers //
  ///////////////

  modifier notPaused(address _contractAddress) {
    require(!isGlobalPaused, "all markets paused");
    require(!isMarketPaused[_contractAddress], "market paused");
    _;
  }

  ////////////
  // Events //
  ////////////

  /**
   * @dev Emitted when the address resolver is set.
   */
  event AddressResolverSet(IAddressResolver addressResolver);
  /**
   * @dev Emitted when synthetix contracts are updated.
   */
  event SynthetixAddressesUpdated(
    ISynthetix synthetix,
    IExchanger exchanger,
    IExchangeRates exchangeRates,
    ICollateralShort collateralShort,
    IDelegateApprovals delegateApprovals
  );
  /**
   * @dev Emitted when all markets paused.
   */
  event GlobalPaused(bool isPaused);
  /**
   * @dev Emitted when single market paused.
   */
  event MarketPaused(address contractAddress, bool isPaused);
  /**
   * @dev Emitted when trading cut-off is set.
   */
  event TradingCutoffSet(address indexed contractAddress, uint tradingCutoff);
  /**
   * @dev Emitted when quote key is set.
   */
  event QuoteKeySet(address indexed contractAddress, bytes32 quoteKey);
  /**
   * @dev Emitted when base key is set.
   */
  event BaseKeySet(address indexed contractAddress, bytes32 baseKey);
  event BaseSwappedForQuote(
    address indexed marketAddress,
    address indexed exchanger,
    uint baseSwapped,
    uint quoteReceived
  );
  event QuoteSwappedForBase(
    address indexed marketAddress,
    address indexed exchanger,
    uint quoteSwapped,
    uint baseReceived
  );
}
