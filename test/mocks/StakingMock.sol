pragma solidity 0.4.18;

import "../../contracts/interfaces/IStaking.sol";


contract StakingMock is IStaking {
    uint256 amount;
    uint8 lockUnit;
    uint64 lockEnds;
    address unlocker;
    bytes32 metadata;

    event Unlock(address indexed account, uint256 indexed lockId);
    event UnlockPartial(address indexed account, uint256 indexed lockId, uint256 amount);
    event MovedTokens(address indexed from, address indexed to, uint256 amount);

    function setLock(uint256 _amount, uint8 _lockUnit, uint64 _lockEnds, address _unlocker, bytes32 _metadata) public {
        amount = _amount;
        lockUnit = _lockUnit;
        lockEnds = _lockEnds;
        unlocker = _unlocker;
    }

    function unlock(address _acct, uint256 _lockId) public {
        Unlock(_acct, _lockId);
    }

    function moveTokens(address _from, address _to, uint256 _amount) {
        MovedTokens(_from, _to, _amount);
    }

    function unlockAndMoveTokens(address _from, uint256 _lockId, address _to, uint256 _amount) external {
        UnlockPartial(_from, _lockId, _amount);
        MovedTokens(_from, _to, _amount);
    }

    function getLock(address _acct, uint256 _lockId) public view returns (uint256, uint8, uint64, address, bytes32) {
        return (amount, lockUnit, lockEnds, unlocker, metadata);
    }


}
