// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.9;

import "../synthetix/SignedDecimalMath.sol";
import "../synthetix/DecimalMath.sol";

/**
 * @title Geometric Moving Average Oracle
 * @author Lyra
 * @dev Instances of stored oracle data, "observations", are collected in the oracle array
 *
 * Every pool is initialized with an oracle array length of 65535. Since block timestamps are ~15sec apart,
 * this will support call backs at the very least 270 days on mainnet ethereum (on optimism, an order of magnitude more).
 *
 * When the array is fully populated the next Observation overwrites an existing slot by wrapping around the array.
 *
 * The GWAV values are calculated from the blockTimestamps and "q" accumulator values of two Observations. These
 * observations are scaled to the requested timestamp.
 */
library GWAV {
  using DecimalMath for uint;
  using SignedDecimalMath for int;

  /// @dev Internally this library uses 18 decimals of precision
  uint private constant UNIT = 1e18;
  /// @dev Below this value, the result is always 0
  int private constant MIN_EXP = -41 * int(UNIT);
  /// @dev Above this value precision is lost, and uint256s cannot handle the size
  uint private constant MAX_EXP = 100 * UNIT;
  /// @dev Total number of Observations stored in the Oracle
  uint16 private constant arrayLen = 65535;
  uint private constant LN_2 = 693147180559945309;

  /// @dev Stores all past Observations and the current index
  struct Params {
    Observation[arrayLen] observations;
    uint16 index;
  }

  /// @dev An observation holds the cumulative log value of all historic observations (accumulator)
  /// and other relevant fields for computing the next accumulator value.
  /// @dev A pair of oracle Observations is used to deduce the GWAV TWAP
  struct Observation {
    // TODO: consider packing into a single 256 byte struct
    int q; // accumulator value used to compute GWAV
    uint nextVal; // value at the time the observation was made, used to calculate the next q value
    uint blockTimestamp;
    bool initialized;
  }

  /////////////
  // Setters //
  /////////////

  /**
   * @notice Initialize the oracle array by writing the first Observation.
   * @dev Called once for the lifecycle of the observations array
   * @dev First Observation uses blockTimestamp as the time interval to prevent manipulation of the GWAV immediately
   * after initialization
   * @param self Stores past Observations and the index of the latest Observation
   * @param newVal First observed value for blockTimestamp
   * @param blockTimestamp Timestamp of first Observation
   */
  function initialize(
    Params storage self,
    uint newVal,
    uint blockTimestamp
  ) internal {
    // if Observation older than blockTimestamp is used for GWAV,
    // _getFirstBefore() will scale the first Observation "q" accordingly
    _initializeWithManualQ(self, ln(newVal) * int(blockTimestamp), newVal, blockTimestamp);
  }

  /**
   * @notice Writes an oracle Observation to the GWAV array
   * @dev Observation index wraps around the observations[arrayLen] array when arrayLen is exceeded
   * @dev Writable at most once per block. BlockTimestamp must be > last.blockTimestamp
   * @param self Stores past Observations and the index of the latest Observation
   * @param nextVal Value at given blockTimestamp
   * @param blockTimestamp Current blockTimestamp
   */
  function write(
    Params storage self,
    uint nextVal,
    uint blockTimestamp
  ) internal {
    Observation memory last = self.observations[self.index];

    // Ensure entries are sequential
    require(blockTimestamp >= last.blockTimestamp, "invalid block timestamp");

    // early return if we've already written an observation this block
    if (last.blockTimestamp == blockTimestamp) {
      self.observations[self.index].nextVal = nextVal;
      return;
    }
    // No reason to record an entry if it's the same as the last one
    if (last.nextVal == nextVal) return;

    // update accumulator value
    // assumes the market value between the previous and current blockTimstamps was "last.nextVal"
    uint timestampDelta = blockTimestamp - last.blockTimestamp;
    int newQ = last.q + ln(last.nextVal) * int(timestampDelta);

    // update latest index and store Observation
    uint16 indexUpdated = (self.index + 1) % arrayLen;
    self.observations[indexUpdated] = _transform(newQ, nextVal, blockTimestamp);
    self.index = indexUpdated;
  }

  /////////////
  // Getters //
  /////////////

  /**
   * @notice Calculates the geometric moving average between two Observations A & B. These observations are scaled to
   * the requested timestamps
   * @dev For the current GWAV value, "0" may be passed in for secondsAgo
   * @dev If timestamps A==B, returns the value at A/B.
   * @param self Stores past Observations and the index of the latest Observation
   * @param secondsAgoA Seconds from blockTimestamp to Observation A
   * @param secondsAgoB Seconds from blockTimestamp to Observation B
   */
  function getGWAVForPeriod(
    Params storage self,
    uint secondsAgoA,
    uint secondsAgoB
  ) public view returns (uint) {
    (int q0, uint t0) = queryFirstBeforeAndScale(self, block.timestamp, secondsAgoA);
    (int q1, uint t1) = queryFirstBeforeAndScale(self, block.timestamp, secondsAgoB);

    if (t0 == t1) {
      return (exp(q1 / int(t1)));
    }

    return exp((q1 - q0) / int(t1 - t0));
  }

  /**
   * @notice Returns the GWAV accumulator/timestamps values for each "secondsAgo" in the array `secondsAgos[]`
   * @param currentBlockTimestamp Timestamp of current block
   * @param secondsAgos Array of all timestamps for which to export accumulator/timestamp values
   */
  function observe(
    Params storage self,
    uint currentBlockTimestamp,
    uint[] memory secondsAgos
  ) public view returns (int[] memory qCumulatives, uint[] memory timestamps) {
    qCumulatives = new int[](secondsAgos.length);
    timestamps = new uint[](secondsAgos.length);
    for (uint i = 0; i < secondsAgos.length; i++) {
      (qCumulatives[i], timestamps[i]) = queryFirstBefore(self, currentBlockTimestamp, secondsAgos[i]);
    }
  }

  //////////////////////////////////////////////////////
  // Querying observation closest to target timestamp //
  //////////////////////////////////////////////////////

  /**
   * @notice Finds the first observation before a timestamp "secondsAgo" from the "currentBlockTimestamp"
   * @dev If target falls between two Observations, the older one is returned
   * @dev See _queryFirstBefore() for edge cases where target lands
   * after the newest Observation or before the oldest Observation
   * @dev Reverts if secondsAgo exceeds the currentBlockTimestamp
   * @param self Stores past Observations and the index of the latest Observation
   * @param currentBlockTimestamp Timestamp of current block
   * @param secondsAgo Seconds from currentBlockTimestamp to target Observation
   */
  function queryFirstBefore(
    Params storage self,
    uint currentBlockTimestamp,
    uint secondsAgo
  ) internal view returns (int qCumulative, uint timestamp) {
    uint target = currentBlockTimestamp - secondsAgo;
    Observation memory beforeOrAt = _queryFirstBefore(self, target);

    return (beforeOrAt.q, beforeOrAt.blockTimestamp);
  }

  function queryFirstBeforeAndScale(
    Params storage self,
    uint currentBlockTimestamp,
    uint secondsAgo
  ) internal view returns (int qCumulative, uint timestamp) {
    uint target = currentBlockTimestamp - secondsAgo;
    Observation memory beforeOrAt = _queryFirstBefore(self, target);

    int timestampDelta = int(target - beforeOrAt.blockTimestamp);

    return (beforeOrAt.q + (ln(beforeOrAt.nextVal) * timestampDelta), target);
  }

  /**
   * @notice Finds the first observation before the "target" timestamp
   * @dev Checks for trivial scenarios before entering _binarySearch()
   * @dev Assumes initialize() has been called
   * @param self Stores past Observations and the index of the latest Observation
   * @param target BlockTimestamp of target Observation
   */
  function _queryFirstBefore(Params storage self, uint target) private view returns (Observation memory beforeOrAt) {
    // Case 1: target blockTimestamp is at or after the most recent Observation
    beforeOrAt = self.observations[self.index];
    if (beforeOrAt.blockTimestamp <= target) {
      return (beforeOrAt);
    }

    // Now, set to the oldest observation
    // If the next index is not initialized, this means the index array has not fully filled up yet
    beforeOrAt = self.observations[(self.index + 1) % arrayLen];
    if (!beforeOrAt.initialized) beforeOrAt = self.observations[0];

    // Case 2: target blockTimestamp is older than the oldest Observation
    // The observation is scaled to the target using the nextVal
    if (beforeOrAt.blockTimestamp > target) {
      return _transform((beforeOrAt.q * int(target)) / int(beforeOrAt.blockTimestamp), beforeOrAt.nextVal, target);
    }

    // Case 3: target is within the recorded Observations.
    return _binarySearch(self, target);
  }

  /**
   * @notice Finds closest Observation using binary search
   * @dev Used when the target is located within the stored observation boundaries
   * e.g. Older than the most recent observation and younger, or the same age as, the oldest observation
   * @dev Returns the Observation which is older than target (instead of newer)
   * @param self Stores past Observations and the index of the latest Observation
   * @param target BlockTimestamp of target Observation
   */
  function _binarySearch(Params storage self, uint target) private view returns (Observation memory beforeOrAt) {
    Observation memory atOrAfter;

    uint oldest = (self.index + 1) % arrayLen; // oldest observation
    uint newest = oldest + arrayLen - 1; // newest observation
    uint i;
    while (true) {
      i = (oldest + newest) / 2;
      beforeOrAt = self.observations[i % arrayLen];

      // we've landed on an uninitialized tick, increment the index of oldest observation
      if (!beforeOrAt.initialized) {
        oldest = i + 1;
        continue;
      }

      atOrAfter = self.observations[(i + 1) % arrayLen];
      bool targetAtOrAfter = beforeOrAt.blockTimestamp <= target;

      // check if we've found the answer!
      if (targetAtOrAfter && target <= atOrAfter.blockTimestamp) break;
      // TODO: check if worth the optimization (compare with Uniswap)
      // else if (target == atOrAfter.blockTimestamp) {
      //   beforeOrAt = atOrAfter;
      //   break;
      // }

      if (!targetAtOrAfter) newest = i - 1;
      else oldest = i + 1;
    }
  }

  /////////////
  // Utility //
  /////////////

  /**
   * @notice Creates the first Observation with manual Q accumulator value.
   * @param qVal Initial GWAV accumulator value
   * @param nextVal First observed value for blockTimestamp
   * @param blockTimestamp Timestamp of Observation
   */
  function _initializeWithManualQ(
    Params storage self,
    int qVal,
    uint nextVal,
    uint blockTimestamp
  ) internal {
    self.observations[0] = Observation({q: qVal, nextVal: nextVal, blockTimestamp: blockTimestamp, initialized: true});
  }

  /**
   * @dev Creates an Observation given a GWAV accumulator, latest value, and a blockTimestamp
   */
  function _transform(
    int newQ,
    uint nextVal,
    uint blockTimestamp
  ) private pure returns (Observation memory) {
    return Observation({q: newQ, nextVal: nextVal, blockTimestamp: blockTimestamp, initialized: true});
  }

  //////////
  // Math //
  //////////

  /**
   * @dev Returns the floor relative to UINT
   */
  function floor(uint x) internal pure returns (uint) {
    return x - (x % UNIT);
  }

  /**
   * @dev Returns the natural log of the value using Halley's method.
   * 0.000001 -> 1000000+ work fine
   * this contract will deal with values between 0.3-10, so very safe for this method
   */
  function ln(uint x) internal pure returns (int) {
    int res;
    int next;

    for (uint i = 0; i < 8; i++) {
      int e = int(exp(res));

      next = res + ((int(x) - e) * 2).divideDecimalRound(int(x) + e);

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
  function exp(uint x) public pure returns (uint) {
    if (x == 0) {
      return UNIT;
    }
    require(x <= MAX_EXP, "cannot handle exponents greater than 100");

    uint k = floor(x.divideDecimalRound(LN_2)) / UNIT;
    uint p = 2**k;
    uint r = x - (k * LN_2);

    uint _t = UNIT;

    uint lastT;
    for (uint8 i = 16; i > 0; i--) {
      _t = _t.multiplyDecimalRound(r / i) + UNIT;
      if (_t == lastT) {
        break;
      }
      lastT = _t;
    }

    return p * _t;
  }

  /**
   * @dev Returns the exponent of the value using taylor expansion with range reduction,
   * with support for negative numbers.
   */
  function exp(int x) public pure returns (uint) {
    if (0 <= x) {
      return exp(uint(x));
    } else if (x < MIN_EXP) {
      // exp(-63) < 1e-27, so we just return 0
      return 0;
    } else {
      return UNIT.divideDecimalRound(exp(uint(-x)));
    }
  }
}
