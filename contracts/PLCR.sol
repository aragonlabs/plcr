pragma solidity 0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/lib/misc/Migrations.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/lib/math/SafeMath64.sol";

import "staking/contracts/IStakingLocking.sol"; // TODO: unifiy with Curation somewhere
import "@aragon/apps-curation/contracts/interfaces/IVoting.sol"; // TODO: unifiy with Curation somewhere


contract PLCR is AragonApp, IVoting {
    using SafeMath for uint256;
    using SafeMath64 for uint64;

    IStakingLocking public staking;
    uint256 public voteQuorum;
    uint256 public minorityBlocSlash;
    uint64 public commitDuration;
    uint64 public revealDuration;

    uint256 constant public PCT_BASE = 10 ** 18; // 0% = 0; 1% = 10^16; 100% = 10^18

    bytes32 constant public CREATE_VOTE_ROLE = keccak256("CREATE_VOTE_ROLE");

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

    mapping(address => mapping(uint256 => bool)) usedLocks;

    event NewVote(uint256 voteId);
    event CommitedVote(uint256 voteId, address voter, uint256 stake, bytes32 secretHash);
    event RevealedVote(uint256 indexed voteId, address voter, uint256 stake, bool option);
    event ClaimedTokens(uint256 indexed voteId, address voter);

    /**
     * @notice Initialize App with Staking app at `_staking`, needed quorum of `(_voteQuorum - _voteQuorum % 10^16) / 10^14`, minority bloc slash of `(_minorityBlocSlash - _minorityBlocSlash % 10^16) / 10^14`, commit duration of `(_commitDuration - _commitDuration % 86400) / 86400` day `_commitDuration >= 172800 ? 's' : ''` and reveal duration of `(_revealDuration - _revealDuration % 86400) / 86400` day `_revealDuration >= 172800 ? 's' : ''`
     * @param _staking Address of app used for staking and locking tokens
     * @param _voteQuorum Percentage of cast votes needed to pass a Vote
     * @param _minorityBlocSlash Percentage of tokens used for voting that will be redistributed from the losing side to the winning one
     * @param _commitDuration Duration in seconds of the Commit period
     * @param _revealDuration Duration in seconds of the Reveal period
     */
    function initialize(
        IStakingLocking _staking,
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

    /**
     * @notice Create a new vote about "`_metadata`"
     * @param _script EVM script to be executed on approval
     * @param _metadata Vote metadata
     * @return voteId Id for newly created vote
     */
    function newVote(bytes _script, string _metadata) isInitialized external auth(CREATE_VOTE_ROLE) returns (uint256 voteId) {
        voteId = votes.length++;

        Vote storage vote = votes[voteId];
        vote.commitEndDate = getTimestamp64().add(commitDuration);
        vote.revealEndDate = vote.commitEndDate.add(revealDuration);
        vote.metadata = _metadata;

        emit NewVote(voteId);
        return voteId;
    }

    /**
     * @notice Commit to vote `_voteId` using lock with id `_lockId` for option contained in hash `_secretHash`
     * @param _voteId Id of the Vote
     * @param _secretHash Hash obtained from own salt and voting option
     * @param _lockId Id of the lock from Staking app used for this vote
     */
    function commitVote(uint256 _voteId, bytes32 _secretHash, uint256 _lockId) isInitialized public {
        Vote storage vote = votes[_voteId];

        // check commit period for Vote
        require(getTimestamp64() <= vote.commitEndDate);

        // check lock and get amount
        uint256 stake = checkLock(msg.sender, _lockId, vote.revealEndDate);

        // move slash proportion to here
        uint256 slashStake = stake.mul(minorityBlocSlash) / PCT_BASE;
        staking.transferFromLock(msg.sender, _lockId, slashStake, address(this), 0);
        vote.slashPool = vote.slashPool.add(slashStake);

        vote.userVotes[msg.sender] = UserVote({
            lockId: _lockId,
            stake: stake,
            secretHash: _secretHash,
            revealed: false,
            voteOption: false,
            claimed: false
        });

        emit CommitedVote(_voteId, msg.sender, stake, _secretHash);
    }

    /**
     * @notice Reveal option `_voteOption` for Vote `_voteId` with salt `_salt`
     * @param _voteId Id of the Vote
     * @param _voteOption Option that was preciously commited for
     * @param _salt Salt used in previous vote commit
     */
    function revealVote(uint256 _voteId, bool _voteOption, bytes32 _salt) isInitialized public {
        Vote storage vote = votes[_voteId];
        UserVote storage userVote = votes[_voteId].userVotes[msg.sender];

        // check reveal period
        require(vote.commitEndDate < getTimestamp64());
        require(getTimestamp64() <= vote.revealEndDate);

        // check salt
        require(userVote.secretHash == keccak256(abi.encodePacked(keccak256(abi.encodePacked(_voteOption ? "1" : "0")), keccak256(abi.encodePacked(_salt)))));

        // make sure it's not revealed twice
        require(!userVote.revealed);
        userVote.revealed = true;

        userVote.voteOption = _voteOption;

        if (_voteOption) {
            vote.votesFor = vote.votesFor.add(userVote.stake);
        } else {
            vote.votesAgainst = vote.votesAgainst.add(userVote.stake);
        }

        // unlock own tokens
        staking.unlock(msg.sender, userVote.lockId);

        // delete used lock
        delete(usedLocks[msg.sender][userVote.lockId]);

        emit RevealedVote(_voteId, msg.sender, userVote.stake, _voteOption);
    }

    /**
     * @notice Claim tokens for vote `_voteid`
     * @param _voteId Id of the Vote
     */
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

        // winning side
        if (userVote.revealed && userVote.voteOption == vote.result) {
            // compute proportional reward
            uint256 winningVotes = vote.result ? vote.votesFor : vote.votesAgainst;
            uint256 amount = vote.slashPool.mul(userVote.stake) / winningVotes;
            // move tokens from Voting to voter
            staking.transfer(amount, msg.sender, 0);
            // keep track of paid rewards
            vote.paidReward = vote.paidReward.add(amount);
        }

        emit ClaimedTokens(_voteId, msg.sender);
    }

    /**
     * @notice Get vote details for Vote `_voteId`
     * @param _voteId Id of the Vote
     * @return commitEndDate End of commit period
     * @return revealEndDate End of reveal period
     * @return result Vote result
     * @return computed Whether Vote result has been already computed
     * @return metadata Vote metadata
     * @return votesFor Amount of positive votes
     * @return votesAgainst Amount of negative votes
     * @return totalVotes Total amount of cast votes
     * @return slashPool Amount of tokens to be redristibuted from winning side to losing one
     * @return paidReward Amount of tokens that have been redistributed so far
     */
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

    /**
     * @notice Get details for Vote `_voteId` and voter `_voter`
     * @param _voteId Id of the Vote
     * @param _voter Address of voter
     * @return lockId Id of lock in Staking app used for voting
     * @return stake Amount staked for this Vote
     * @return secretHash Hash obtained from own salt and voting option
     * @return revealed Whether the voting option has already been revealed by voter
     * @return voteOption Cast vote option
     * @return claimed Whether the voter has already claimed the reward
     */
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

    /**
     * @notice Check if the Vote `_voteId` has already been closed.
     * @param _voteId Id of the Vote
     * @return Boolean indicating whether the Vote has been closed
     */
    function isClosed(uint256 _voteId) view public returns (bool) {
        return getTimestamp64() > votes[_voteId].revealEndDate;
    }

    /**
     * @notice Get vote result for Vote `_voteId`
     * @param _voteId Id of the Vote
     * @return result Vote result
     * @return winningStake Total amount of tokens on the winning side
     * @return totalStake Total amount of tokens that participated in the Vote
     */
    function getVoteResult(uint256 _voteId) public returns (bool result, uint256 winningStake, uint256 totalStake) {
        if (!isClosed(_voteId)) {
            return (false, 0, 0);
        }

        Vote storage vote = votes[_voteId];

        if (!vote.computed) {
            computeVote(_voteId);
        }

        result = vote.result;
        winningStake = vote.result ? vote.votesFor : vote.votesAgainst;
        totalStake = vote.totalVotes;
    }

    /**
     * @notice Get stake for Vote `_voteId` used by voter `_voter`
     * @param _voteId Id of the Vote
     * @param _voter Address of voter
     * @return Stake used by boter in this Vote
     */
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

    function checkLock(address user, uint256 _lockId, uint64 _endDate) internal returns (uint256) {
        // check lockId was not used before
        require(!usedLocks[user][_lockId]);
        // mark it as used
        usedLocks[user][_lockId] = true;

        // get the lock
        uint256 amount;
        uint64 unlockedAt;
        address unlocker;
        (amount, unlockedAt, unlocker, ) = staking.getLock(msg.sender, _lockId);
        // check unlocker
        require(unlocker == address(this));
        // check time
        require(unlockedAt >= _endDate);

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
}
