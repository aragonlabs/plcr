pragma solidity 0.4.18;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/lib/misc/Migrations.sol";
import "@aragon/os/contracts/lib/zeppelin/math/SafeMath.sol";
import "@aragon/os/contracts/lib/zeppelin/math/SafeMath64.sol";

import "./interfaces/IStaking.sol"; // TODO: unifiy with Curation somewhere
import "./interfaces/IVoting.sol"; // TODO: unifiy with Curation somewhere


contract PLCR is AragonApp, IVoting {
    using SafeMath for uint256;
    using SafeMath64 for uint64;

    IStaking public staking;
    uint256 public voteQuorum;
    uint256 public minorityBlocSlash;
    uint64 public commitDuration;
    uint64 public revealDuration;

    uint256 constant public PCT_BASE = 10 ** 18; // 0% = 0; 1% = 10^16; 100% = 10^18

    bytes32 constant public CREATE_VOTE_ROLE = keccak256("CREATE_VOTE_ROLE");

    // TODO!!!
    enum TimeUnit { Blocks, Seconds }

    struct UserVote {
        uint256 lockId;
        uint256 stake;
        bytes32 secretHash;
        bool revealed;
        bool voteOption;
        bool claimed;
    }

    struct Vote {
        uint64 commitEndDate;
        uint64 revealEndDate;
        bool result;
        bool computed;
        string metadata;
        mapping(address => UserVote) userVotes;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 totalVotes;
        uint256 slashPool;
        uint256 paidReward;
    }

    Vote[] votes;

    mapping(uint256 => bool) usedLocks;

    event NewVote(uint256 voteId);
    event CommitedVote(uint256 voteId, address voter, bytes32 secretHash);
    event RevealedVote(uint256 indexed voteId, address voter, bool option);
    event ClaimedTokens(uint256 indexed voteId, address voter);

    function initialize(
        IStaking _staking,
        uint256 _voteQuorum,
        uint256 _minorityBlocSlash,
        uint64 _commitDuration,
        uint64 _revealDuration
    )
        onlyInit
        external
    {
        initialized();

        require(isContract(_staking));
        require(_voteQuorum <= PCT_BASE);
        require(_minorityBlocSlash <= PCT_BASE);

        staking = _staking;
        voteQuorum = _voteQuorum;
        minorityBlocSlash = _minorityBlocSlash;
        commitDuration = _commitDuration;
        revealDuration = _revealDuration;
    }

    function newVote(bytes _script, string _metadata) isInitialized external auth(CREATE_VOTE_ROLE) returns (uint256 voteId) {
        voteId = votes.length++;

        Vote storage vote = votes[voteId];
        vote.commitEndDate = getTimestamp().add(commitDuration);
        vote.revealEndDate = vote.commitEndDate.add(revealDuration);
        vote.metadata = _metadata;

        NewVote(voteId);
        return voteId;
    }

    function commitVote(uint256 _voteId, bytes32 _secretHash, uint256 _lockId) isInitialized public {
        Vote storage vote = votes[_voteId];

        // check commit period for Vote
        require(getTimestamp() <= vote.commitEndDate);

        // check lock and get amount
        uint256 stake = checkLock(_lockId, vote.revealEndDate);

        // move slash proportion to here
        uint256 slashStake = stake.mul(minorityBlocSlash) / PCT_BASE;
        staking.unlockAndMoveTokens(msg.sender, _lockId, address(this), slashStake);
        vote.slashPool = vote.slashPool.add(slashStake);

        vote.userVotes[msg.sender] = UserVote({
            lockId: _lockId,
            stake: stake,
            secretHash: _secretHash,
            revealed: false,
            voteOption: false,
            claimed: false
        });

        CommitedVote(_voteId, msg.sender, _secretHash);
    }

    function revealVote(uint256 _voteId, bool _voteOption, bytes32 _salt) isInitialized public {
        Vote storage vote = votes[_voteId];
        UserVote storage userVote = votes[_voteId].userVotes[msg.sender];

        // check reveal period
        require(vote.commitEndDate < getTimestamp());
        require(getTimestamp() <= vote.revealEndDate);

        // check salt
        require(userVote.secretHash == keccak256(keccak256(_voteOption ? '1' : '0'), keccak256(_salt)));

        // make sure it's not revealed twice
        require(!userVote.revealed);
        userVote.revealed = true;

        userVote.voteOption = _voteOption;

        if (_voteOption) {
            vote.votesFor = vote.votesFor.add(userVote.stake);
        } else {
            vote.votesAgainst = vote.votesAgainst.add(userVote.stake);
        }

        RevealedVote(_voteId, msg.sender, _voteOption);
    }

    function claimTokens(uint256 _voteId) isInitialized public {
        // check Vote is over
        require(isClosed(_voteId));

        Vote storage vote = votes[_voteId];
        UserVote storage userVote = votes[_voteId].userVotes[msg.sender];

        // make sure not claimed twice
        require(!userVote.claimed);
        userVote.claimed = true;

        if (!vote.computed) {
            computeVote(_voteId);
        }

        // unlock own tokens
        staking.unlock(msg.sender, userVote.lockId);

        // winning side
        if (userVote.revealed && userVote.voteOption == vote.result) {
            // compute proportional reward
            uint256 winningVotes = vote.result ? vote.votesFor : vote.votesAgainst;
            uint256 amount = vote.slashPool.mul(userVote.stake) / winningVotes;
            // move tokens from Voting to voter
            staking.moveTokens(address(this), msg.sender, amount);
            // keep track of paid rewards
            vote.paidReward = vote.paidReward.add(amount);
        }

        ClaimedTokens(_voteId, msg.sender);
    }

    function getVote(
        uint256 _voteId
    )
        view
        public
        returns (
            uint64 commitEndDate,
            uint64 revealEndDate,
            bool result,
            bool computed,
            string metadata,
            uint256 votesFor,
            uint256 votesAgainst,
            uint256 totalVotes,
            uint256 slashPool,
            uint256 paidReward
        )
    {
        Vote memory vote = votes[_voteId];
        commitEndDate = vote.commitEndDate;
        revealEndDate = vote.revealEndDate;
        result = vote.result;
        computed = vote.computed;
        metadata = vote.metadata;
        votesFor = vote.votesFor;
        votesAgainst = vote.votesAgainst;
        totalVotes = vote.totalVotes;
        slashPool = vote.slashPool;
        paidReward = vote.paidReward;
    }

    function getUserVote(
        uint256 _voteId,
        address _voter
    )
        view
        public
        returns (
            uint256 lockId,
            uint256 stake,
            bytes32 secretHash,
            bool revealed,
            bool voteOption,
            bool claimed
        )
    {
        UserVote memory userVote = votes[_voteId].userVotes[_voter];
        lockId = userVote.lockId;
        stake = userVote.stake;
        secretHash = userVote.secretHash;
        revealed = userVote.revealed;
        voteOption = userVote.voteOption;
        claimed = userVote.claimed;
    }

    // Voting interface

    function isClosed(uint256 _voteId) view public returns (bool) {
        return getTimestamp() > votes[_voteId].revealEndDate;
    }

    function getVoteResult(uint256 _voteId) public returns (bool result, uint256 winningStake, uint256 totalStake) {
        if (!isClosed(_voteId)) {
            return (false, 0, 0);
        }

        Vote memory vote = votes[_voteId];

        if (!vote.computed) {
            computeVote(_voteId);
        }

        result = vote.result;
        winningStake = vote.result ? vote.votesFor : vote.votesAgainst;
        totalStake = vote.totalVotes;
    }

    function getVoterWinningStake(uint256 _voteId, address _voter) public returns (uint256) {
        UserVote storage userVote = votes[_voteId].userVotes[_voter];

        if (!isClosed(_voteId)) {
            return 0;
        }

        if (!userVote.revealed) {
            return 0;
        }

        if (!votes[_voteId].computed) {
            computeVote(_voteId);
        }

        if (userVote.voteOption == votes[_voteId].result) {
            return userVote.stake;
        }

        return 0;
    }

    function checkLock(uint256 _lockId, uint64 _date) internal returns (uint256) {
        // check lockId was not used before
        require(!usedLocks[_lockId]);
        // get the lock
        uint256 amount;
        uint8 lockUnit;
        uint64 lockEnds;
        address unlocker;
        (amount, lockUnit, lockEnds, unlocker, ) = staking.getLock(msg.sender, _lockId);
        // check unlocker
        require(unlocker == address(this));
        // check time
        require(lockUnit == uint8(TimeUnit.Seconds));
        require(lockEnds >= _date);

        // mark it as used
        usedLocks[_lockId] = true;

        return amount;
    }

    function computeVote(uint256 _voteId) internal {
        require(isClosed(_voteId));

        Vote storage vote = votes[_voteId];

        vote.totalVotes = vote.votesFor.add(vote.votesAgainst);

        if (vote.totalVotes == 0) {
            vote.result = false;
        } else {
            uint256 computedPct = vote.votesFor.mul(PCT_BASE) / vote.totalVotes;
            vote.result = computedPct >= voteQuorum;
        }

        vote.computed = true;
    }

    function getTimestamp() view internal returns (uint64) {
        return uint64(now);
    }
}
