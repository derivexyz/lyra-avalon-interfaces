//SPDX-License-Identifier: ISC
pragma solidity ^0.8.9;

interface IDelegateApprovals {
  function approveExchangeOnBehalf(address delegate) external;
}
