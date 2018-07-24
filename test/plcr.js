const { assertRevert } = require('@aragon/test-helpers/assertThrow')
const keccak256 = require('js-sha3').keccak_256

const getContract = name => artifacts.require(name)
const getEvent = (receipt, event, arg) => { return receipt.logs.filter(l => l.event == event)[0].args[arg] }
const pct16 = x => new web3.BigNumber(x).times(new web3.BigNumber(10).toPower(16))

contract('PLCR', ([owner, voter1, voter2, _]) => {
  let app, staking

  const voteQuorum = pct16(50)
  const minorityBlocSlash = pct16(80)
  const commitDuration = 1000
  const revealDuration = 1000
  const stake = 100
  const lockId = 1
  const salt = 'salt'.repeat(8)

  const TIME_UNIT_BLOCKS = 0
  const TIME_UNIT_SECONDS = 1

  const secretHash = (voteOption) => {
    let node = keccak256(voteOption ? '1' : '0')
    node = keccak256(new Buffer(node + keccak256(salt), 'hex'))
    return '0x' + node
  }

  context('Regular app', async() => {
    beforeEach(async () =>{
      staking = await getContract('StakingMock').new()

      app = await getContract('PLCRMock').new()
      await app.initialize(staking.address, voteQuorum, minorityBlocSlash, commitDuration, revealDuration)
    })

    it('checks initial values are right', async () => {
      assert.equal(await app.staking.call(), staking.address, "Staking address should match")
      assert.equal((await app.voteQuorum.call()).toString(), voteQuorum.toString(), "voteQuorum should match")
      assert.equal((await app.minorityBlocSlash.call()).toString(), minorityBlocSlash, "minorityBlocSlash should match")
      assert.equal((await app.commitDuration.call()).toString(), commitDuration, "commitDuration should match")
      assert.equal((await app.revealDuration.call()).toString(), revealDuration, "revealDuration should match")
    })

    it('fails on reinitialization', async () => {
      return assertRevert(async () => {
        await app.initialize(staking.address, voteQuorum, minorityBlocSlash, commitDuration, revealDuration)
      })
    })

    // aux action functions

    const createVote = async () => {
      const r = await app.newVote("", "", { from: voter1 })
      const voteId = getEvent(r, "NewVote", "voteId")

      return voteId
    }

    const commitVote = async (voter, voteOption) => {
      const voteId = await createVote()
      // mock lock
      const startLock = await app.getTimestampExt.call()
      const endLock = startLock.add(commitDuration + revealDuration + 1)
      await staking.setLock(stake, TIME_UNIT_SECONDS, startLock, endLock, app.address, "")

      const receipt = await app.commitVote(voteId, secretHash(voteOption), lockId, { from: voter })

      return { voteId: voteId, receipt: receipt }
    }

    const revealVote = async (voter, voteOption) => {
      const {voteId} = await commitVote(voter, voteOption)

      await app.addTime(commitDuration + 1)

      await app.revealVote(voteId, voteOption, salt, { from: voter })

      return voteId
    }

    // checks if a lockId for a given account was unlocked
    const checkUnlocked = (_receipt, _account, _unlocker, _lockId) => {
      const logs = _receipt.receipt.logs.filter(
        l =>
          l.topics[0] == web3.sha3('Unlocked(address,address,uint256)') &&
          '0x' + l.topics[1].slice(26) == _account &&
          '0x' + l.topics[2].slice(26) == _unlocker &&
          web3.toDecimal(l.topics[3]) == _lockId
      )
      return logs.length == 1
    }

    // checks if a lockId for a given account was partially unlocked for certain amount
    const checkUnlockedPartial = (_receipt, _account, _unlocker, _lockId, _amount) => {
      const logs = _receipt.receipt.logs.filter(
        l =>
          l.topics[0] == web3.sha3('UnlockedPartial(address,address,uint256,uint256)') &&
          '0x' + l.topics[1].slice(26) == _account &&
          '0x' + l.topics[2].slice(26) == _unlocker &&
          web3.toDecimal(l.topics[3]) == _lockId &&
          web3.toDecimal(l.data) == _amount
      )
      return logs.length == 1
    }

    // checks if a log for moving tokens was generated with the given params
    // if amount is 0, it will check for any
    const checkMovedTokens = (_receipt, _from, _to, _amount) => {
      const logs = _receipt.receipt.logs.filter(
        l =>
          l.topics[0] == web3.sha3('MovedTokens(address,address,uint256)') &&
          '0x' + l.topics[1].slice(26) == _from &&
          '0x' + l.topics[2].slice(26) == _to &&
          (web3.toDecimal(l.data) == _amount || _amount == 0)
      )
      return logs.length == 1 || (_amount == 0 && logs.length >= 1)
    }

    // ----------- Create vote --------------

    it('creates vote', async () => {
      const voteId = await createVote()
      const vote = await app.getVote.call(voteId)
      const currentTime = await app.getTimestampExt.call()
      // checks
      assert.equal(vote[0].toString(), (currentTime.add(commitDuration)).toString(), "Commit end date should match")
      assert.equal(vote[1].toString(), (currentTime.add(commitDuration).add(revealDuration)).toString(), "Reveal end date should match")
      assert.equal(vote[2], false, "Result should match")
      assert.equal(vote[3], false, "Computed should match")
      assert.equal(vote[4], "", "Metadata should match")
      assert.equal(vote[5], 0, "Votes For should match")
      assert.equal(vote[6], 0, "Votes Against should match")
      assert.equal(vote[7], 0, "Total votes should match")
      assert.equal(vote[8], 0, "Slash Pool should match")
      assert.equal(vote[9], 0, "Paid Reward should match")
    })

    // ----------- Commit votes --------------
    it('commits vote For', async () => {
      const voteOption = true
      const {voteId, receipt} = await commitVote(voter1, voteOption)
      // checks
      const slashPool = minorityBlocSlash.mul(stake).dividedToIntegerBy(pct16(100))
      assert.isTrue(checkUnlockedPartial(receipt, voter1, app.address, lockId, slashPool))
      assert.isTrue(checkMovedTokens(receipt, voter1, app.address, slashPool))
      const userVote = await app.getUserVote.call(voteId, voter1)
      assert.equal(userVote[0].toString(), lockId, "lockId should match")
      assert.equal(userVote[1].toString(), stake, "Stake should match")
      assert.equal(userVote[2], secretHash(true), "Secret Hash should match")
      assert.equal(userVote[3], false, "Revealed should match")
      assert.equal(userVote[4], false, "Vote Option should match")
      assert.equal(userVote[5], false, "Claimed should match")
      const vote = await app.getVote.call(voteId)
      assert.equal(vote[5].toString(), 0, "Votes For should match")
      assert.equal(vote[6].toString(), 0, "Votes against should match")
      assert.equal(vote[7].toString(), 0, "Total votes should match")
      assert.equal(vote[8].toString(), minorityBlocSlash.mul(stake).dividedToIntegerBy(pct16(100)), "Slash pool should match")
      assert.equal(vote[9].toString(), 0, "Paid rewards should match")
    })

    it('commits vote Against', async () => {
      const voteOption = false
      const {voteId, receipt} = await commitVote(voter1, voteOption)
      // checks
      const slashPool = minorityBlocSlash.mul(stake).dividedToIntegerBy(pct16(100))
      assert.isTrue(checkUnlockedPartial(receipt, voter1, app.address, lockId, slashPool))
      assert.isTrue(checkMovedTokens(receipt, voter1, app.address, slashPool))
      const userVote = await app.getUserVote.call(voteId, voter1)
      assert.equal(userVote[0].toString(), lockId, "lockId should match")
      assert.equal(userVote[1].toString(), stake, "Stake should match")
      assert.equal(userVote[2], secretHash(false), "Secret Hash should match")
      assert.equal(userVote[3], false, "Revealed should match")
      assert.equal(userVote[4], false, "Vote Option should match")
      assert.equal(userVote[5], false, "Claimed should match")
      const vote = await app.getVote.call(voteId)
      assert.equal(vote[5].toString(), 0, "Votes For should match")
      assert.equal(vote[6].toString(), 0, "Votes against should match")
      assert.equal(vote[7].toString(), 0, "Total votes should match")
      assert.equal(vote[8].toString(), minorityBlocSlash.mul(stake).dividedToIntegerBy(pct16(100)), "Slash pool should match")
      assert.equal(vote[9].toString(), 0, "Paid rewards should match")
    })

    it('fails if trying to commit after commit period', async () => {
      const voteId = await createVote()
      // mock lock
      const startLock = await app.getTimestampExt.call()
      const endLock = startLock.add(commitDuration + revealDuration + 1)
      await staking.setLock(stake, TIME_UNIT_SECONDS, startLock, endLock, app.address, "")

      await app.addTime(commitDuration + 1)

      return assertRevert(async () => {
        await app.commitVote(voteId, secretHash(true), lockId, { from: voter1 })
      })
    })

    it('fails if lock has wrong unlocker', async () => {
      const voteId = await createVote()
      // mock lock
      const startLock = await app.getTimestampExt.call()
      const endLock = startLock.add(commitDuration + revealDuration + 1)
      await staking.setLock(stake, TIME_UNIT_SECONDS, startLock, endLock, owner, "")

      return assertRevert(async () => {
        await app.commitVote(voteId, secretHash(true), lockId, { from: voter1 })
      })
    })

    it('fails if lock has wrong unit', async () => {
      const voteId = await createVote()
      // mock lock
      const startLock = await app.getTimestampExt.call()
      const endLock = startLock.add(commitDuration + revealDuration + 1)
      await staking.setLock(stake, TIME_UNIT_BLOCKS, startLock, endLock, app.address, "")

      return assertRevert(async () => {
        await app.commitVote(voteId, secretHash(true), lockId, { from: voter1 })
      })
    })

    it('fails if lock has wrong end date', async () => {
      const voteId = await createVote()
      // mock lock
      const startLock = await app.getTimestampExt.call()
      const endLock = startLock
      await staking.setLock(stake, TIME_UNIT_SECONDS, startLock, endLock, app.address, "")

      return assertRevert(async () => {
        await app.commitVote(voteId, secretHash(true), lockId, { from: voter1 })
      })
    })

    it('fails if lock was already used', async () => {
      const voteId = await createVote()
      // mock lock
      const startLock = await app.getTimestampExt.call()
      const endLock = startLock.add(commitDuration + revealDuration + 1)
      await staking.setLock(stake, TIME_UNIT_SECONDS, startLock, endLock, app.address, "")
      await app.commitVote(voteId, secretHash(true), lockId, { from: voter1 })

      return assertRevert(async () => {
        await app.commitVote(voteId, secretHash(true), lockId, { from: voter1 })
      })
    })

    // ----------- Reveal votes --------------

    it('Reveals vote For', async () => {
      const voteId = await revealVote(voter1, true)
      // check votesFor, against and total
      const vote = await app.getVote.call(voteId)
      assert.equal(vote[5].toString(), stake, "Votes For should match")
      assert.equal(vote[6].toString(), 0, "Votes against should match")
      assert.equal(vote[7].toString(), 0, "Total votes should match")
    })

    it('Reveals vote Against', async () => {
      const voteId = await revealVote(voter1, false)
      // check votesFor, against and total
      const vote = await app.getVote.call(voteId)
      assert.equal(vote[5].toString(), 0, "Votes For should match")
      assert.equal(vote[6].toString(), stake, "Votes against should match")
      assert.equal(vote[7].toString(), 0, "Total votes should match")
    })

    it('fails trying to reveal if reveal period has not started yet', async () => {
      const voteOption = true
      const {voteId} = await commitVote(voter1, voteOption)

      return assertRevert(async () => {
        await app.revealVote(voteId, voteOption, salt, { from: voter1 })
      })
    })

    it('fails trying to reveal if reveal period is over', async () => {
      const voteOption = true
      const {voteId} = await commitVote(voter1, voteOption)

      await app.addTime(commitDuration + revealDuration + 1)

      return assertRevert(async () => {
        await app.revealVote(voteId, voteOption, salt, { from: voter1 })
      })
    })

    it('fails trying to reveal if secret hash does not match', async () => {
      const voteOption = true
      const {voteId} = await commitVote(voter1, voteOption)

      await app.addTime(commitDuration + 1)

      return assertRevert(async () => {
        await app.revealVote(voteId, voteOption, 'fakeSalt', { from: voter1 })
      })
    })

    it('fails trying to reveal twice', async () => {
      const voteOption = true
      const voteId = await revealVote(voter1, voteOption)

      return assertRevert(async () => {
        await app.revealVote(voteId, voteOption, salt, { from: voter1 })
      })
    })

    // ----------- Claim tokens --------------

    it('Claim tokens For, 1 voter', async () => {
      const voteId = await revealVote(voter1, true)

      await app.addTime(revealDuration + 1)

      await app.claimTokens(voteId, { from: voter1 })

      // checks
      const slashPool = minorityBlocSlash.mul(stake).dividedToIntegerBy(pct16(100))
      const vote = await app.getVote.call(voteId)
      assert.equal(vote[5].toString(), stake, "Votes For should match")
      assert.equal(vote[6].toString(), 0, "Votes against should match")
      assert.equal(vote[7].toString(), stake, "Total votes should match")
      assert.equal(vote[8].toString(), slashPool.toString(), "Slash pool should match")
      assert.equal(vote[9].toString(), slashPool.toString(), "Paid reward should match")
    })

    it('Claim tokens Against, 2 voters', async () => {
      const lockId1 = 1
      const lockId2 = 2
      const stake1 = 2 * stake
      const stake2 = stake
      const voteOption1 = false
      const voteOption2 = true

      // create vote
      const voteId = await createVote()

      // commit vote
      // Voter 1
      // mock lock
      const startLock = await app.getTimestampExt.call()
      const endLock = startLock.add(commitDuration + revealDuration + 1)
      await staking.setLock(stake1, TIME_UNIT_SECONDS, startLock, endLock, app.address, "")
      await app.commitVote(voteId, secretHash(voteOption1), lockId1, { from: voter1 })
      // Voter 2
      // mock lock
      await staking.setLock(stake2, TIME_UNIT_SECONDS, startLock, endLock, app.address, "")
      await app.commitVote(voteId, secretHash(voteOption2), lockId2, { from: voter2 })

      // Reveal votes
      await app.addTime(commitDuration + 1)

      await app.revealVote(voteId, voteOption1, salt, { from: voter1 })
      await app.revealVote(voteId, voteOption2, salt, { from: voter2 })

      // claim rewards
      await app.addTime(revealDuration + 1)
      const slashPool = minorityBlocSlash.mul(stake).dividedToIntegerBy(pct16(100)).mul(3)

      // Voter 1
      const r1 = await app.claimTokens(voteId, { from: voter1 })

      let vote = await app.getVote.call(voteId)
      assert.equal(vote[5].toString(), stake2, "Votes For should match")
      assert.equal(vote[6].toString(), stake1, "Votes against should match")
      assert.equal(vote[7].toString(), stake1 + stake2, "Total votes should match")
      assert.equal(vote[8].toString(), slashPool.toString(), "Slash pool should match")
      assert.equal(vote[9].toString(), slashPool.toString(), "Paid reward should match")
      assert.isTrue(await checkMovedTokens(r1, app.address, voter1, slashPool))

      // Voter 2
      const r2 = await app.claimTokens(voteId, { from: voter2 })

      vote = await app.getVote.call(voteId)
      assert.equal(vote[5].toString(), stake2, "Votes For should match")
      assert.equal(vote[6].toString(), stake1, "Votes against should match")
      assert.equal(vote[7].toString(), stake1 + stake2, "Total votes should match")
      assert.equal(vote[8].toString(), slashPool.toString(), "Slash pool should match")
      assert.equal(vote[9].toString(), slashPool.toString(), "Paid reward should match")
      assert.isFalse(await checkMovedTokens(r2, app.address, voter2, 0))
    })

    it('Claim tokens without any reveal', async () => {
      const {voteId} = await commitVote(voter1, true)

      await app.addTime(commitDuration + revealDuration + 1)

      await app.claimTokens(voteId, { from: voter1 })

      // checks
      const slashPool = minorityBlocSlash.mul(stake).dividedToIntegerBy(pct16(100))
      const vote = await app.getVote.call(voteId)
      assert.equal(vote[5].toString(), 0, "Votes For should match")
      assert.equal(vote[6].toString(), 0, "Votes against should match")
      assert.equal(vote[7].toString(), 0, "Total votes should match")
      assert.equal(vote[8].toString(), slashPool.toString(), "Slash pool should match")
      assert.equal(vote[9].toString(), 0, "Paid reward should match")
    })

    it('fails claiming before vote is closed', async () => {
      const voteId = await revealVote(voter1, true)

      return assertRevert(async () => {
        await app.claimTokens(voteId, { from: voter1 })
      })
    })

    it('fails claiming twice', async () => {
      const voteId = await revealVote(voter1, true)

      await app.addTime(revealDuration + 1)

      await app.claimTokens(voteId, { from: voter1 })

      return assertRevert(async () => {
        await app.claimTokens(voteId, { from: voter1 })
      })
    })

    // ----------- IVoting interface --------------

    it('uses getVoteResult', async () => {
      const voteId = await revealVote(voter1, true)

      await app.addTime(revealDuration + 1)

      // first one is to modify state
      await app.getVoteResult(voteId)
      const vote = await app.getVoteResult.call(voteId)
      assert.equal(vote[0], true, "Result should match")
      assert.equal(vote[1], stake, "Winning stake should match")
      assert.equal(vote[2], stake, "Total stake should match")
    })

    it('uses getVoteResult before vote closing', async () => {
      const voteId = await revealVote(voter1, true)

      // first one is to modify state
      await app.getVoteResult(voteId)
      const vote = await app.getVoteResult.call(voteId)
      assert.equal(vote[0], false, "Result should match")
      assert.equal(vote[1], 0, "Winning stake should match")
      assert.equal(vote[2], 0, "Total stake should match")
    })

    it('uses getVoteResult without any reveal', async () => {
      const {voteId} = await commitVote(voter1, true)

      await app.addTime(commitDuration + revealDuration + 1)

      // first one is to modify state
      await app.getVoteResult(voteId)
      const vote = await app.getVoteResult.call(voteId)
      assert.equal(vote[0], false, "Result should match")
      assert.equal(vote[1], 0, "Winning stake should match")
      assert.equal(vote[2], 0, "Total stake should match")
    })

    it('uses getVoterWinningStake', async () => {
      const voteId = await revealVote(voter1, true)

      await app.addTime(revealDuration + 1)

      // first one is to modify state
      await app.getVoterWinningStake(voteId, voter1)
      const voterWinningStake = await app.getVoterWinningStake.call(voteId, voter1)
      assert.equal(voterWinningStake, stake, "Voter winning stake should match")
    })

    it('uses getVoterWinningStake before closing Vote', async () => {
      const voteId = await revealVote(voter1, true)

      // first one is to modify state
      await app.getVoterWinningStake(voteId, voter1)
      const voterWinningStake = await app.getVoterWinningStake.call(voteId, voter1)
      assert.equal(voterWinningStake, 0, "Voter winning stake should match")
    })

    it('uses getVoterWinningStake without revealing', async () => {
      const {voteId} = await commitVote(voter1, true)

      await app.addTime(commitDuration + revealDuration + 1)

      // first one is to modify state
      await app.getVoterWinningStake(voteId, voter1)
      const voterWinningStake = await app.getVoterWinningStake.call(voteId, voter1)
      assert.equal(voterWinningStake, 0, "Voter winning stake should match")
    })

    it('uses getVoterWinningStake from the losing side', async () => {
      const lockId1 = 1
      const lockId2 = 2
      const stake1 = stake
      const stake2 = 2 * stake
      const voteOption1 = false
      const voteOption2 = true

      // create vote
      const voteId = await createVote()

      // commit vote
      // Voter 1
      // mock lock
      const startLock = await app.getTimestampExt.call()
      const endLock = startLock.add(commitDuration + revealDuration + 1)
      await staking.setLock(stake1, TIME_UNIT_SECONDS, startLock, endLock, app.address, "")
      await app.commitVote(voteId, secretHash(voteOption1), lockId1, { from: voter1 })
      // Voter 2
      // mock lock
      await staking.setLock(stake2, TIME_UNIT_SECONDS, startLock, endLock, app.address, "")
      await app.commitVote(voteId, secretHash(voteOption2), lockId2, { from: voter2 })

      // Reveal votes
      await app.addTime(commitDuration + 1)

      await app.revealVote(voteId, voteOption1, salt, { from: voter1 })
      await app.revealVote(voteId, voteOption2, salt, { from: voter2 })

      await app.addTime(revealDuration + 1)

      // first one is to modify state
      await app.getVoterWinningStake(voteId, voter1)
      const voterWinningStake = await app.getVoterWinningStake.call(voteId, voter1)
      assert.equal(voterWinningStake, 0, "Voter winning stake should match")
    })

    // ----------- misc --------------

    it('tries to compute before closing', async () => {
      const voteOption = false
      const {voteId, receipt} = await commitVote(voter1, voteOption)
      return assertRevert(async () => {
        await app.computeVoteExternal(voteId)
      })
    })
  })

  context('Without init', async () => {
    beforeEach(async () =>{
      staking = await getContract('StakingMock').new()

      app = await getContract('PLCRMock').new()
    })

    it('fails trying to create new Vote', async () => {
      return assertRevert(async () => {
        await app.newVote("", "")
      })
    })

    it('fails trying to commit', async () => {
      return assertRevert(async () => {
        await app.commitVote(1, secretHash(true), 1)
      })
    })

    it('fails trying to reveal', async () => {
      return assertRevert(async () => {
        await app.revealVote(1, true, salt)
      })
    })

    it('fails trying to claim', async () => {
      return assertRevert(async () => {
        await app.claimTokens(1)
      })
    })

    it('fails trying to init with bad staking', async () => {
      return assertRevert(async () => {
        await app.initialize(owner, voteQuorum, minorityBlocSlash, commitDuration, revealDuration)
      })
    })

    it('fails trying to init with bad vote Quorum', async () => {
      return assertRevert(async () => {
        await app.initialize(staking.address, pct16(101), minorityBlocSlash, commitDuration, revealDuration)
      })
    })

    it('fails trying to init with bad Minority Bloc Slash', async () => {
      return assertRevert(async () => {
        await app.initialize(staking.address, voteQuorum, pct16(101), commitDuration, revealDuration)
      })
    })
  })

  context('Without mock wrapper', async () => {
    beforeEach(async () =>{
      staking = await getContract('StakingMock').new()

      app = await getContract('PLCR').new()
      await app.initialize(staking.address, voteQuorum, minorityBlocSlash, commitDuration, revealDuration)
    })

    // just for 100% coverage
    it('calls isClosed to use getTimestamp', async () => {
      const r = await app.newVote("", "", { from: voter1 })
      const voteId = getEvent(r, "NewVote", "voteId")

      const closed = await app.isClosed.call(voteId)
      assert.isFalse(closed, "Vote shouldn't be closed yet")
    })
  })
})
