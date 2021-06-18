// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

interface IOperable {
    // Update the status of the operator
    function updateOperator(address _operator, bool _status) external;
}
