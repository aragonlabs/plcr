pragma solidity 0.4.18;

import "../../contracts/PLCR.sol";


contract PLCRMock is PLCR {
    uint64 _mockTime = uint64(now);

    function getTimestampExt() external view returns (uint64) {
        return getTimestamp();
    }

    function setTimestamp(uint64 i) public {
        _mockTime = i;
    }

    function addTime(uint64 i) public {
        _mockTime += i;
    }

    function computeVoteExternal(uint256 _voteId) public {
        computeVote(_voteId);
    }

    function getTimestamp() internal view returns (uint64) {
        return _mockTime;
    }

    function getUsedLock(address user, uint256 lockId) view public returns (bool) {
        return usedLocks[user][lockId];
    }
}
