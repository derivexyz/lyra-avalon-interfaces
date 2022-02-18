//SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// Libraries
import "../synthetix/SignedDecimalMath.sol";
import "../synthetix/DecimalMath.sol";

/**
 * @title BlackScholes
 * @author Lyra
 * @dev Contract to compute the black scholes price of options. Where the unit is unspecified, it should be treated as a
 * PRECISE_DECIMAL, which has 1e27 units of precision. The default decimal matches the ethereum standard of 1e18 units
 * of precision.
 */
library BlackScholes {
  using DecimalMath for uint;
  using SignedDecimalMath for int;

  struct PricesDeltaStdVega {
    uint callPrice;
    uint putPrice;
    int callDelta;
    int putDelta;
    uint stdVega;
  }

  /**
   * @param timeToExpirySec Number of seconds to the expiry of the option
   * @param volatilityDecimal Implied volatility over the period til expiry as a percentage
   * @param spotDecimal The current price of the base asset
   * @param strikeDecimal The strike price of the option
   * @param rateDecimal The percentage risk free rate + carry cost
   */
  struct BlackScholesInputs {
    uint timeToExpirySec;
    uint volatilityDecimal;
    uint spotDecimal;
    uint strikeDecimal;
    int rateDecimal;
  }

  uint private constant SECONDS_PER_YEAR = 31536000;
  /// @dev Internally this library uses 27 decimals of precision
  uint private constant PRECISE_UNIT = 1e27;
  uint private constant LN_2_PRECISE = 693147180559945309417232122;
  uint private constant SQRT_TWOPI = 2506628274631000502415765285;
  /// @dev Below this value, return 0
  int private constant MIN_CDF_STD_DIST_INPUT = (int(PRECISE_UNIT) * -45) / 10; // -4.5
  /// @dev Above this value, return 1
  int private constant MAX_CDF_STD_DIST_INPUT = int(PRECISE_UNIT) * 10;
  /// @dev Below this value, the result is always 0
  int private constant MIN_EXP = -63 * int(PRECISE_UNIT);
  /// @dev Above this value the a lot of precision is lost, and uint256s come close to not being able to handle the size
  uint private constant MAX_EXP = 100 * PRECISE_UNIT;
  /// @dev Value to use to avoid any division by 0 or values near 0
  uint private constant MIN_T_ANNUALISED = PRECISE_UNIT / SECONDS_PER_YEAR; // 1 second
  uint private constant MIN_VOLATILITY = PRECISE_UNIT / 10000; // 0.001%
  uint private constant VEGA_STANDARDISATION_MIN_DAYS = 7 days;

  /////////////////////////////////////
  // Option Pricing public functions //
  /////////////////////////////////////

  /**
   * @dev Returns call and put prices for options with given parameters.
   */
  function optionPrices(BlackScholesInputs memory bsInput) internal pure returns (uint call, uint put) {
    uint tAnnualised = annualise(bsInput.timeToExpirySec);
    uint spotPrecise = bsInput.spotDecimal.decimalToPreciseDecimal();
    uint strikePrecise = bsInput.strikeDecimal.decimalToPreciseDecimal();
    int ratePrecise = bsInput.rateDecimal.decimalToPreciseDecimal();
    (int d1, int d2) = d1d2(
      tAnnualised,
      bsInput.volatilityDecimal.decimalToPreciseDecimal(),
      spotPrecise,
      strikePrecise,
      ratePrecise
    );
    (call, put) = _optionPrices(tAnnualised, spotPrecise, strikePrecise, ratePrecise, d1, d2);
    return (call.preciseDecimalToDecimal(), put.preciseDecimalToDecimal());
  }

  /**
   * @dev Returns call/put prices and delta/stdVega for options with given parameters.
   */
  function pricesDeltaStdVega(BlackScholesInputs memory bsInput) internal pure returns (PricesDeltaStdVega memory) {
    uint tAnnualised = annualise(bsInput.timeToExpirySec);
    uint spotPrecise = bsInput.spotDecimal.decimalToPreciseDecimal();

    (int d1, int d2) = d1d2(
      tAnnualised,
      bsInput.volatilityDecimal.decimalToPreciseDecimal(),
      spotPrecise,
      bsInput.strikeDecimal.decimalToPreciseDecimal(),
      bsInput.rateDecimal.decimalToPreciseDecimal()
    );
    (uint callPrice, uint putPrice) = _optionPrices(
      tAnnualised,
      spotPrecise,
      bsInput.strikeDecimal.decimalToPreciseDecimal(),
      bsInput.rateDecimal.decimalToPreciseDecimal(),
      d1,
      d2
    );
    uint v = _standardVega(d1, spotPrecise, bsInput.timeToExpirySec);
    (int callDelta, int putDelta) = _delta(d1);

    return
      PricesDeltaStdVega(
        callPrice.preciseDecimalToDecimal(),
        putPrice.preciseDecimalToDecimal(),
        callDelta.preciseDecimalToDecimal(),
        putDelta.preciseDecimalToDecimal(),
        v
      );
  }

  //////////////////////
  // Computing Greeks //
  //////////////////////

  /**
   * @dev Returns internal coefficients of the Black-Scholes call price formula, d1 and d2.
   * @param tAnnualised Number of years to expiry
   * @param volatility Implied volatility over the period til expiry as a percentage
   * @param spot The current price of the base asset
   * @param strike The strike price of the option
   * @param rate The percentage risk free rate + carry cost
   */
  function d1d2(
    uint tAnnualised,
    uint volatility,
    uint spot,
    uint strike,
    int rate
  ) internal pure returns (int d1, int d2) {
    // Set minimum values for tAnnualised and volatility to not break computation in extreme scenarios
    // These values will result in option prices reflecting only the difference in stock/strike, which is expected.
    // This should be caught before calling this function, however the function shouldn't break if the values are 0.
    tAnnualised = tAnnualised < MIN_T_ANNUALISED ? MIN_T_ANNUALISED : tAnnualised;
    volatility = volatility < MIN_VOLATILITY ? MIN_VOLATILITY : volatility;

    int vtSqrt = int(volatility.multiplyDecimalRoundPrecise(sqrtPrecise(tAnnualised)));
    int log = ln(spot.divideDecimalRoundPrecise(strike));
    int v2t = (int(volatility.multiplyDecimalRoundPrecise(volatility) / 2) + rate).multiplyDecimalRoundPrecise(
      int(tAnnualised)
    );
    d1 = (log + v2t).divideDecimalRoundPrecise(vtSqrt);
    d2 = d1 - vtSqrt;
  }

  /**
   * @dev Internal coefficients of the Black-Scholes call price formula.
   * @param tAnnualised Number of years to expiry
   * @param spot The current price of the base asset
   * @param strike The strike price of the option
   * @param rate The percentage risk free rate + carry cost
   * @param d1 Internal coefficient of Black-Scholes
   * @param d2 Internal coefficient of Black-Scholes
   */
  function _optionPrices(
    uint tAnnualised,
    uint spot,
    uint strike,
    int rate,
    int d1,
    int d2
  ) internal pure returns (uint call, uint put) {
    uint strikePV = strike.multiplyDecimalRoundPrecise(exp(-rate.multiplyDecimalRoundPrecise(int(tAnnualised))));
    uint spotNd1 = spot.multiplyDecimalRoundPrecise(stdNormalCDF(d1));
    uint strikeNd2 = strikePV.multiplyDecimalRoundPrecise(stdNormalCDF(d2));

    // We clamp to zero if the minuend is less than the subtrahend
    // In some scenarios it may be better to compute put price instead and derive call from it depending on which way
    // around is more precise.
    call = strikeNd2 <= spotNd1 ? spotNd1 - strikeNd2 : 0;
    put = call + strikePV;
    put = spot <= put ? put - spot : 0;
  }

  /*
   * Greeks
   */

  /**
   * @dev Returns the option's delta value
   * @param d1 Internal coefficient of Black-Scholes
   */
  function _delta(int d1) internal pure returns (int callDelta, int putDelta) {
    callDelta = int(stdNormalCDF(d1));
    putDelta = callDelta - int(PRECISE_UNIT);
  }

  /**
   * @dev Returns the option's vega value based on d1
   *
   * @param d1 Internal coefficient of Black-Scholes
   * @param tAnnualised Number of years to expiry
   * @param spot The current price of the base asset
   */
  function _vega(
    uint tAnnualised,
    uint spot,
    int d1
  ) internal pure returns (uint vega) {
    return sqrtPrecise(tAnnualised).multiplyDecimalRoundPrecise(stdNormal(d1).multiplyDecimalRoundPrecise(spot));
  }

  /**
   * @dev Returns the option's vega value with expiry modified to be at least VEGA_STANDARDISATION_MIN_DAYS
   * @param d1 Internal coefficient of Black-Scholes
   * @param spot The current price of the base asset
   * @param timeToExpirySec Number of seconds to expiry
   */
  function _standardVega(
    int d1,
    uint spot,
    uint timeToExpirySec
  ) internal pure returns (uint) {
    uint tAnnualised = annualise(timeToExpirySec);

    timeToExpirySec = timeToExpirySec < VEGA_STANDARDISATION_MIN_DAYS ? VEGA_STANDARDISATION_MIN_DAYS : timeToExpirySec;
    uint daysToExpiry = (timeToExpirySec * PRECISE_UNIT) / 1 days;
    uint thirty = 30 * PRECISE_UNIT;
    uint normalisationFactor = sqrtPrecise(thirty.divideDecimalRoundPrecise(daysToExpiry)) / 100;
    return _vega(tAnnualised, spot, d1).multiplyDecimalRoundPrecise(normalisationFactor).preciseDecimalToDecimal();
  }

  /////////////////////
  // Math Operations //
  /////////////////////

  /**
   * @dev Returns absolute value of an int as a uint.
   */
  function abs(int x) internal pure returns (uint) {
    return uint(x < 0 ? -x : x);
  }

  /**
   * @dev Returns the floor of a PRECISE_UNIT (x - (x % 1e27))
   */
  function floor(uint x) internal pure returns (uint) {
    return x - (x % PRECISE_UNIT);
  }

  /**
   * @dev Returns the natural log of the value using Halley's method.
   */
  function ln(uint x) internal pure returns (int) {
    int res;
    int next;

    for (uint i = 0; i < 8; i++) {
      int e = int(exp(res));

      next = res + ((int(x) - e) * 2).divideDecimalRoundPrecise(int(x) + e);

      if (next == res) {
        break;
      }
      res = next;
    }

    return res;
  }

  /**
   * @dev Returns the exponent of the value using taylor expansion with range reduction.
   */
  function exp(uint x) internal pure returns (uint) {
    if (x == 0) {
      return PRECISE_UNIT;
    }
    require(x <= MAX_EXP, "cannot handle exponents greater than 100");

    uint k = floor(x.divideDecimalRoundPrecise(LN_2_PRECISE)) / PRECISE_UNIT;
    uint p = 2**k;
    uint r = x - (k * LN_2_PRECISE);

    uint _t = PRECISE_UNIT;

    uint lastT;
    for (uint8 i = 16; i > 0; i--) {
      _t = _t.multiplyDecimalRoundPrecise(r / i) + PRECISE_UNIT;
      if (_t == lastT) {
        break;
      }
      lastT = _t;
    }

    return p * _t;
  }

  /**
   * @dev Returns the exponent of the value using taylor expansion with range reduction, with support for negative
   * numbers.
   */
  function exp(int x) internal pure returns (uint) {
    if (0 <= x) {
      return exp(uint(x));
    } else if (x < MIN_EXP) {
      // exp(-63) < 1e-27, so we just return 0
      return 0;
    } else {
      return PRECISE_UNIT.divideDecimalRoundPrecise(exp(uint(-x)));
    }
  }

  /**
   * @dev Returns the square root of the value using Newton's method. This ignores the unit, so numbers should be
   * multiplied by their unit before being passed in.
   */
  function sqrt(uint x) internal pure returns (uint y) {
    uint z = (x + 1) / 2;
    y = x;
    while (z < y) {
      y = z;
      z = (x / z + z) / 2;
    }
  }

  /**
   * @dev Returns the square root of the value using Newton's method.
   */
  function sqrtPrecise(uint x) internal pure returns (uint) {
    // Add in an extra unit factor for the square root to gobble;
    // otherwise, sqrt(x * UNIT) = sqrt(x) * sqrt(UNIT)
    return sqrt(x * PRECISE_UNIT);
  }

  /**
   * @dev The standard normal distribution of the value.
   */
  function stdNormal(int x) internal pure returns (uint) {
    return exp(-x.multiplyDecimalRoundPrecise(x / 2)).divideDecimalRoundPrecise(SQRT_TWOPI);
  }

  /*
   * @dev The standard normal cumulative distribution of the value. Only has to operate precisely between -1 and 1 for
   * the calculation of option prices, but handles up to -4 with good accuracy.
   */
  function stdNormalCDF(int x) internal pure returns (uint) {
    // Based on testing, errors are ~0.1% at -4, which is still acceptable; and around 0.3% at -4.5.
    // This function seems to become increasingly inaccurate past -5 ( >%5 inaccuracy)
    // At that range, the values are so low at that we will return 0, as it won't affect any usage of this value.
    if (x < MIN_CDF_STD_DIST_INPUT) {
      return 0;
    }

    // Past 10, this will always return 1 at the level of precision we are using
    if (x > MAX_CDF_STD_DIST_INPUT) {
      return PRECISE_UNIT;
    }

    int t1 = int(1e7 + int((2315419 * abs(x)) / PRECISE_UNIT));
    uint exponent = uint(x.multiplyDecimalRoundPrecise(x / 2));
    int d = int((3989423 * PRECISE_UNIT) / exp(exponent));
    uint prob = uint(
      (d *
        (3193815 +
          ((-3565638 + ((17814780 + ((-18212560 + (13302740 * 1e7) / t1) * 1e7) / t1) * 1e7) / t1) * 1e7) /
          t1) *
        1e7) / t1
    );
    if (x > 0) prob = 1e14 - prob;
    return (PRECISE_UNIT * prob) / 1e14;
  }

  /**
   * @dev Converts an integer number of seconds to a fractional number of years.
   */
  function annualise(uint secs) internal pure returns (uint yearFraction) {
    return secs.divideDecimalRoundPrecise(SECONDS_PER_YEAR);
  }
}
