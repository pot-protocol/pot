// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import "../contracts/PotScore.sol";
import "../contracts/PotFactory.sol";
import "../contracts/PotPool.sol";

/// @dev Minimal 6-decimal mock standing in for USDC on Base.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @title PotPool test suite
/// @notice Exercises the full lifecycle of a Pot circle. Since the
///         block.prevrandao shuffle was replaced with Chainlink VRF, starting a
///         pool is a two-phase operation: filling the roster only *requests*
///         randomness (state -> Pending); the rotation order is locked when the
///         VRF coordinator calls back (state -> Active). Tests drive that
///         callback with VRFCoordinatorV2_5Mock.
///
/// @dev    IMPORTANT TEST-HARNESS NOTE: PotPool hardcodes the Base mainnet USDC
///         address in its constructor. To test against MockUSDC we `vm.etch` the
///         mock's runtime bytecode at that address (approach (a) — the suite runs
///         without modifying the contract; the constructor-arg refactor is still
///         the recommended production fix, see ARCHITECTURE.md).
contract PotPoolTest is Test {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // VRF mock config — values are arbitrary for the mock; the key hash is only
    // a label here, and the subscription is funded far beyond any test's needs.
    bytes32 constant KEY_HASH = keccak256("test-gas-lane");
    uint32  constant CB_GAS_LIMIT = 1_500_000;
    uint16  constant REQ_CONFIRMATIONS = 3;
    bool    constant NATIVE_PAYMENT = false; // LINK, so the mock's fundSubscription applies

    MockUSDC usdc;
    PotScore score;
    PotFactory factory;
    VRFCoordinatorV2_5Mock vrf;

    address treasury = address(0xFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAC0);

    uint256 constant CONTRIB = 100e6; // $100

    function setUp() public {
        // Deploy a mock and graft its code onto the hardcoded Base USDC address.
        MockUSDC mock = new MockUSDC();
        vm.etch(BASE_USDC, address(mock).code);
        usdc = MockUSDC(BASE_USDC);

        // VRF v2.5 mock: (baseFee, gasPrice, weiPerUnitLink).
        vrf = new VRFCoordinatorV2_5Mock(1e17, 1e9, 4e15);

        score = new PotScore();
        factory = new PotFactory(
            address(score),
            treasury,
            address(vrf),
            KEY_HASH,
            CB_GAS_LIMIT,
            REQ_CONFIRMATIONS,
            NATIVE_PAYMENT
        );
        // Factory must own the score registry to authorize pools (deploy invariant).
        score.transferOwnership(address(factory));

        // The factory created its subscription in its constructor; fund it so
        // pools' randomness requests can be fulfilled.
        vrf.fundSubscription(factory.vrfSubId(), 100 ether);

        // Fund participants.
        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        usdc.mint(carol, 1_000e6);
    }

    // ------------------------------------------------------------------
    // Forming
    // ------------------------------------------------------------------

    function test_CreatePool_IndexesAndAuthorizes() public {
        vm.prank(alice);
        address poolAddr = factory.createPool(CONTRIB, 7, 2, false, 0, false);

        assertEq(factory.totalPools(), 1);
        assertTrue(factory.isPool(poolAddr));
        assertTrue(score.authorizedPools(poolAddr), "pool must be score-authorized");

        PotPool pool = PotPool(poolAddr);
        assertEq(pool.creator(), alice);
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Forming));
        assertEq(pool.memberCount(), 1); // creator auto-joins
    }

    function test_CreatePool_RejectsBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Minimum $25"));
        factory.createPool(24e6, 7, 2, false, 0, false);
    }

    function test_PrivatePool_RequiresInvite() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, false));

        vm.prank(bob);
        vm.expectRevert(bytes("No invite"));
        pool.join();

        vm.prank(alice);
        pool.invite(bob);

        vm.prank(bob);
        pool.join(); // fills the 2-person pool and REQUESTS randomness

        // VRF is async: the pool parks in Pending until the coordinator calls back.
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Pending));
        _fulfill(pool);
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Active));
    }

    function test_Start_LocksRotationAndMintsScores() public {
        PotPool pool = _form2(alice, bob);
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Active));

        address[] memory order = pool.getRotationOrder();
        assertEq(order.length, 2);
        // Both members now hold a soulbound Pot Score token.
        assertGt(score.tokenOf(alice), 0);
        assertGt(score.tokenOf(bob), 0);
    }

    // ------------------------------------------------------------------
    // VRF randomness (replaces the old block.prevrandao shuffle)
    // ------------------------------------------------------------------

    /// Filling the roster must NOT lock an order or move to Active by itself — it
    /// only requests randomness. No funds can enter while Pending.
    function test_FillRequestsRandomness_NoOrderUntilFulfilled() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, false));
        vm.prank(alice);
        pool.invite(bob);
        vm.prank(bob);
        pool.join(); // fills -> requests randomness

        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Pending), "must be Pending");
        assertGt(pool.vrfRequestId(), 0, "a VRF request must be open");
        assertEq(pool.getRotationOrder().length, 0, "order must not be locked yet");

        // Funds cannot enter a pool that has not started.
        vm.startPrank(alice);
        usdc.approve(address(pool), CONTRIB);
        vm.expectRevert(bytes("Not active"));
        pool.contribute();
        vm.stopPrank();

        // The callback locks a full, valid rotation order and flips Active.
        _fulfill(pool);
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Active));
        address[] memory order = pool.getRotationOrder();
        assertEq(order.length, 2);
        assertTrue(_isPermutationOf2(order, alice, bob), "order must be a permutation of members");
    }

    /// Only the VRF coordinator may deliver randomness. A spoofed fulfillment
    /// from any other address must revert — otherwise anyone could pick the order.
    function test_FulfillRandomWords_RejectsNonCoordinator() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, false));
        vm.prank(alice);
        pool.invite(bob);
        vm.prank(bob);
        pool.join();

        // Read the request id BEFORE arming expectRevert — otherwise this view
        // call would be the "next call" the cheatcode watches.
        uint256 reqId = pool.vrfRequestId();
        uint256[] memory words = new uint256[](1);
        words[0] = 42;
        vm.prank(address(0xBAD));
        vm.expectRevert(); // OnlyCoordinatorCanFulfill
        pool.rawFulfillRandomWords(reqId, words);

        // Still Pending, nothing locked.
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Pending));
    }

    /// A stuck request (subscription dry, callback dropped) can be reissued after
    /// the retry window. The old request is retired so its stale callback no-ops;
    /// only the new request can activate the pool.
    function test_RetryRotation_ReissuesAfterWindowAndStaleCallbackNoOps() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, false));
        vm.prank(alice);
        pool.invite(bob);
        vm.prank(bob);
        pool.join();

        uint256 firstId = pool.vrfRequestId();

        // Too soon to retry.
        vm.expectRevert(bytes("Retry too soon"));
        pool.retryRotation();

        // After the window, anyone may reissue.
        vm.warp(block.timestamp + pool.RANDOMNESS_RETRY_WINDOW());
        pool.retryRotation();
        uint256 secondId = pool.vrfRequestId();
        assertTrue(secondId != firstId, "retry must issue a fresh request id");
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Pending));

        // A late callback for the SUPERSEDED request is ignored.
        uint256[] memory words = new uint256[](1);
        words[0] = 7;
        vrf.fulfillRandomWordsWithOverride(firstId, address(pool), words);
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Pending), "stale callback must no-op");

        // The current request activates the pool.
        vrf.fulfillRandomWordsWithOverride(secondId, address(pool), words);
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Active));
    }

    // ------------------------------------------------------------------
    // Ordering mode (FIXED vs RANDOM) — v1.1
    // ------------------------------------------------------------------

    /// A private FIXED pool does NOT auto-start on fill and never requests VRF;
    /// the creator starts it, locking the join order, instantly Active.
    function test_FixedPrivatePool_StartsWithoutVRF() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, true)); // private, FIXED
        vm.prank(alice); pool.invite(bob);
        vm.prank(bob);  pool.join(); // fills the roster but must NOT auto-start

        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Forming), "FIXED must not auto-start on fill");
        assertEq(pool.vrfRequestId(), 0, "FIXED must not request VRF");

        vm.prank(alice); pool.startEarly(); // creator starts -> instant Active, no VRF callback
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Active));
        address[] memory order = pool.getRotationOrder();
        assertEq(order.length, 2);
        assertEq(order[0], alice, "join order: creator first");
        assertEq(order[1], bob);
        assertEq(pool.vrfRequestId(), 0, "still no VRF");
    }

    /// A public pool may never use FIXED ordering (creator can't hand out slots).
    function test_FixedPublicPool_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Public pools must use random ordering"));
        factory.createPool(CONTRIB, 7, 2, true, 0, true); // public + fixed -> reject at factory
    }

    /// The creator can arrange the payout order by need before starting.
    function test_SetRotationOrder_ReordersByCreator() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, true));
        vm.prank(alice); pool.invite(bob);
        vm.prank(bob);  pool.join();

        address[] memory ord = new address[](2);
        ord[0] = bob; ord[1] = alice; // bob needs it first
        vm.prank(alice); pool.setRotationOrder(ord);
        vm.prank(alice); pool.startEarly();

        address[] memory got = pool.getRotationOrder();
        assertEq(got[0], bob, "creator-set order respected");
        assertEq(got[1], alice);
    }

    /// setRotationOrder rejects non-permutations and random-order pools.
    function test_SetRotationOrder_RejectsBadInput() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, true));
        vm.prank(alice); pool.invite(bob);
        vm.prank(bob);  pool.join();

        address[] memory short_ = new address[](1); short_[0] = alice;
        vm.prank(alice); vm.expectRevert(bytes("Must cover all members"));
        pool.setRotationOrder(short_);

        address[] memory dup = new address[](2); dup[0] = alice; dup[1] = alice;
        vm.prank(alice); vm.expectRevert(bytes("Duplicate member"));
        pool.setRotationOrder(dup);

        address[] memory nonmem = new address[](2); nonmem[0] = alice; nonmem[1] = carol;
        vm.prank(alice); vm.expectRevert(bytes("Not a member"));
        pool.setRotationOrder(nonmem);

        // a RANDOM-order pool rejects setRotationOrder outright
        vm.prank(alice);
        PotPool randPool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, false));
        address[] memory one = new address[](1); one[0] = alice;
        vm.prank(alice); vm.expectRevert(bytes("Pool uses random ordering"));
        randPool.setRotationOrder(one);
    }

    /// A FIXED pool pays out in the set order and completes the full lifecycle.
    function test_FixedPool_PaysInSetOrderAndCompletes() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, true));
        vm.prank(alice); pool.invite(bob);
        vm.prank(bob);  pool.join();
        address[] memory ord = new address[](2); ord[0] = bob; ord[1] = alice;
        vm.prank(alice); pool.setRotationOrder(ord);
        vm.prank(alice); pool.startEarly();

        uint256 bobBefore = usdc.balanceOf(bob);
        _contribute(pool, alice); _contribute(pool, bob); // round 0 -> bob (slot 0)
        assertEq(usdc.balanceOf(bob) - bobBefore, CONTRIB * 2 - CONTRIB, "bob nets pot minus own stake");

        _contribute(pool, alice); _contribute(pool, bob); // round 1 -> alice, completes
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Complete));
    }

    // ------------------------------------------------------------------
    // Happy-path lifecycle
    // ------------------------------------------------------------------

    function test_FullTwoPersonPool_PaysBothAndCompletes() public {
        PotPool pool = _form2(alice, bob);

        // Round 0: both contribute -> auto-settle pays rotationOrder[0].
        _contribute(pool, alice);
        _contribute(pool, bob);

        // Round 1: both contribute -> auto-settle pays rotationOrder[1], completes.
        _contribute(pool, alice);
        _contribute(pool, bob);

        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Complete));

        // Each member completed exactly one pool.
        (uint16 alicePools,,,,,) = score.scores(alice);
        (uint16 bobPools,,,,,) = score.scores(bob);
        assertEq(alicePools, 1);
        assertEq(bobPools, 1);
    }

    function test_ProtocolFee_IsZero_FullPotToRecipient() public {
        PotPool pool = _form2(alice, bob);

        // rotationOrder[0] is the round-0 recipient; capture their balance.
        address[] memory order = pool.getRotationOrder();
        address recipient = order[0];
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        _contribute(pool, alice);
        _contribute(pool, bob); // settles round 0, pot = 2 * $100 = $200

        // PROTOCOL_FEE_BPS == 0: the treasury receives nothing and the pool
        // retains nothing — the entire pot is disbursed. ("Put in $X, get back
        // $X.") The recipient's own balance nets out the $100 they paid in this
        // round, so the recipient delta is pot - own-stake; the zero-fee invariant
        // is proved by the treasury delta and the emptied pool balance.
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0, "protocol takes nothing");
        assertEq(usdc.balanceOf(address(pool)), 0, "full pot disbursed, no fee retained");
        assertEq(
            usdc.balanceOf(recipient) - recipientBefore,
            CONTRIB * 2 - CONTRIB,
            "recipient nets the pot minus their own stake"
        );
    }

    function test_OnTimeContribution_BuildsStreak() public {
        PotPool pool = _form2(alice, bob);
        _contribute(pool, alice);
        ( , , uint16 onTimeRounds, , uint8 currentStreak, ) = score.scores(alice);
        assertEq(onTimeRounds, 1);
        assertEq(currentStreak, 1);
    }

    // ------------------------------------------------------------------
    // Default / ejection
    // ------------------------------------------------------------------

    function test_Settle_EjectsLateMemberAndMarksScore() public {
        // 3-person pool so one ejection still leaves a payable recipient.
        PotPool pool = _form3(alice, bob, carol);

        // Only alice + bob pay; carol defaults.
        _contribute(pool, alice);
        _contribute(pool, bob);

        // Advance past the deadline + grace, then settle permissionlessly.
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        pool.settle();

        assertFalse(pool.isMember(carol), "defaulter must be ejected");
        ( , , , uint8 carolMissed, , ) = score.scores(carol);
        assertEq(carolMissed, 1, "miss is a permanent mark");
    }

    // ------------------------------------------------------------------
    // Soulbound property
    // ------------------------------------------------------------------

    function test_Score_IsSoulbound() public {
        _form2(alice, bob); // mints soulbound tokens for both members
        uint256 aliceToken = score.tokenOf(alice);

        vm.prank(alice);
        vm.expectRevert(bytes("Soulbound: non-transferable"));
        score.transferFrom(alice, bob, aliceToken);
    }

    function test_GetScore_NeverUnderflows() public {
        // A wallet with a miss but no positive history must clamp to 0, not revert.
        PotPool pool = _form3(alice, bob, carol);
        _contribute(pool, alice);
        _contribute(pool, bob);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        pool.settle(); // carol ejected with a miss, zero on-time rounds

        uint16 carolScore = score.getScore(carol);
        assertEq(carolScore, 0, "damaged record bottoms out at 0, no panic");
    }

    // ------------------------------------------------------------------
    // Stake-at-risk (PUBLIC pools) — v1.1 (#10)
    // ------------------------------------------------------------------

    /// A public pool can't start until the roster is full AND every member has
    /// staked — including the creator (who staked separately, post-construction).
    function test_PublicPool_StartGatesOnAllStaked() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, true, 0, false));

        vm.startPrank(bob); usdc.approve(address(pool), CONTRIB); pool.join(); vm.stopPrank();
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Forming), "full but creator unstaked -> not started");
        assertEq(pool.stakedCount(), 1);
        assertTrue(pool.staked(bob));

        vm.startPrank(alice); usdc.approve(address(pool), CONTRIB); pool.stake(); vm.stopPrank();
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Pending), "all staked + full -> VRF requested");
        assertEq(usdc.balanceOf(address(pool)), CONTRIB * 2, "both stakes held");

        _fulfill(pool);
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Active));
    }

    /// Clean completion: every member gets exactly their stake back, no slashing.
    function test_PublicPool_StakeRefundedOnCleanCompletion() public {
        address[] memory who = new address[](2);
        who[0] = alice; who[1] = bob;
        PotPool pool = _formPublicStaked(who);
        _driveToComplete(pool);
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Complete));
        assertEq(pool.totalSlashed(), 0, "no defaults");

        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice); pool.claimRefund();
        assertEq(usdc.balanceOf(alice) - aBefore, CONTRIB, "stake returned in full");
        vm.prank(bob); pool.claimRefund();
        assertEq(usdc.balanceOf(address(pool)), 0, "all stakes returned, pool empty");
    }

    /// A defaulter's stake is slashed and split equally among the survivors at
    /// completion; the defaulter cannot reclaim anything.
    function test_PublicPool_StakeSlashedAndSplitAmongSurvivors() public {
        address[] memory who = new address[](3);
        who[0] = alice; who[1] = bob; who[2] = carol;
        PotPool pool = _formPublicStaked(who);

        // Pick the defaulter as the first-slot recipient: ejecting them before
        // their slot is paid lets the pool still complete (ejecting the *last*
        // slot's member would cancel — the separate disband/refund gap #5).
        address[] memory order = pool.getRotationOrder();
        address defaulter = order[0];
        (address s1, address s2) = _otherTwo(who, defaulter);

        // round 0: both survivors pay, the defaulter doesn't
        _contribute(pool, s1);
        _contribute(pool, s2);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        pool.settle(); // ejects defaulter, slashes their stake
        assertFalse(pool.isMember(defaulter), "defaulter ejected");
        assertEq(pool.totalSlashed(), CONTRIB, "defaulter's stake slashed");

        _driveToComplete(pool);
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Complete));

        // each survivor: own stake + half of the slashed stake
        uint256 b1 = usdc.balanceOf(s1);
        vm.prank(s1); pool.claimRefund();
        assertEq(usdc.balanceOf(s1) - b1, CONTRIB + CONTRIB / 2, "stake + half of slash");
        vm.prank(s2); pool.claimRefund();

        vm.prank(defaulter);
        vm.expectRevert(bytes("Not a surviving member"));
        pool.claimRefund();

        assertEq(usdc.balanceOf(address(pool)), 0, "all three stakes resolved");
    }

    /// Return the two members of `who` (length 3) that are not `excluded`.
    function _otherTwo(address[] memory who, address excluded) internal pure returns (address a, address b) {
        address[] memory rest = new address[](2);
        uint256 k = 0;
        for (uint256 i = 0; i < who.length; i++) {
            if (who[i] != excluded) { rest[k] = who[i]; k++; }
        }
        return (rest[0], rest[1]);
    }

    /// A public pool that never fills can be cancelled; stakers reclaim in full.
    function test_PublicPool_StakeRefundedOnFormingCancel() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 3, true, 0, false)); // 3 seats, won't fill
        vm.startPrank(bob); usdc.approve(address(pool), CONTRIB); pool.join(); vm.stopPrank();
        vm.startPrank(alice); usdc.approve(address(pool), CONTRIB); pool.stake(); vm.stopPrank();
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Forming), "never filled");

        vm.warp(block.timestamp + 7 days + 1);
        pool.cancelIfExpired();

        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice); pool.claimRefund();
        assertEq(usdc.balanceOf(alice) - aBefore, CONTRIB, "stake back, no slash");
        vm.prank(bob); pool.claimRefund();
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    /// A public pool stuck in Pending (VRF never fulfilled) can be cancelled after
    /// the forming window, recovering the stakes held since Forming.
    function test_PublicPool_StuckInPending_CancelRefundsStakes() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, true, 0, false));
        vm.startPrank(bob); usdc.approve(address(pool), CONTRIB); pool.join(); vm.stopPrank();
        vm.startPrank(alice); usdc.approve(address(pool), CONTRIB); pool.stake(); vm.stopPrank();
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Pending), "VRF requested, not fulfilled");
        assertEq(usdc.balanceOf(address(pool)), CONTRIB * 2, "stakes held during Pending");

        vm.warp(block.timestamp + 7 days + 1);
        pool.cancelIfExpired(); // escape from a stuck Pending
        assertEq(uint8(pool.state()), uint8(PotPool.PoolState.Cancelled));

        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice); pool.claimRefund();
        assertEq(usdc.balanceOf(alice) - aBefore, CONTRIB, "stake recovered");
        vm.prank(bob); pool.claimRefund();
        assertEq(usdc.balanceOf(address(pool)), 0, "all stakes recovered");
    }

    /// Private pools never stake (claimRefund has nothing to give).
    function test_PrivatePool_NoStake() public {
        PotPool pool = _form2(alice, bob);
        assertEq(pool.stakedCount(), 0, "private pools never stake");
        assertFalse(pool.staked(alice));
    }

    // ------------------------------------------------------------------
    // TODO: audit-target edge cases (stubs — implement before mainnet)
    // ------------------------------------------------------------------

    /// Gap: full-wipeout round. If EVERY remaining member misses the same round,
    /// `_ejectMissers` empties `members` and `_payout` must cancel cleanly
    /// rather than revert or pay a ghost. Assert state == Cancelled and no
    /// USDC is sent to a non-member.
    function testTODO_AllMembersMiss_CancelsCleanly() public {
        vm.skip(true);
    }

    /// Gap: stake deposit. The spec calls for each member to lock one round's
    /// contribution at join, released at close, forfeited to remaining members
    /// if ejected post-payout. Not yet implemented on-chain. Test the full
    /// stake lifecycle once added.
    function testTODO_StakeDeposit_LockReleaseForfeit() public {
        vm.skip(true);
    }

    /// Gap: disband refund accounting. On early cancellation the contract should
    /// return net contributions (total in minus total received) to the right
    /// members. Test the reconciliation math.
    function testTODO_Disband_RefundsNetContributions() public {
        vm.skip(true);
    }

    /// Gap: reentrancy. Although CEI is in place and USDC is non-reentrant, a
    /// malicious token (or a future non-USDC pool) could reenter `_payout`.
    /// Test with a reentrant ERC-20 mock and assert no double-payout.
    function testTODO_Payout_ReentrancyGuard() public {
        vm.skip(true);
    }

    /// Gap: lobby expiry. A pool that never fills must not strand its members in
    /// `Forming` forever. After `formingDeadline` (7-day FORMING_WINDOW) anyone
    /// may call `cancelIfExpired`; assert it reverts before the deadline, reverts
    /// once the pool has left `Forming`, and otherwise flips state to `Cancelled`
    /// and emits `PoolCancelled`.
    function testTODO_cancelIfExpired() public {
        vm.skip(true);
    }

    /// Gap: early start. The creator may launch an under-filled pool with
    /// `startEarly` once 2+ members are in. Assert: non-creators are rejected,
    /// a single-member pool is rejected, it only works while `Forming`, and a
    /// successful call moves the pool to `Pending` (then `Active` once VRF calls
    /// back) with a locked rotation order, plus a `PoolStartedEarly` event.
    function testTODO_startEarly() public {
        vm.skip(true);
    }

    /// Gap: refund on cancel. After `cancelIfExpired`, a member calls
    /// `claimRefund`; assert it reverts unless `Cancelled`, reverts for
    /// non-members, emits `RefundClaimed`, and the `refundClaimed` guard blocks a
    /// second claim. Extend to assert the staked USDC is returned once stake
    /// deposits are held on-chain (ties to testTODO_StakeDeposit_*).
    function testTODO_claimRefund() public {
        vm.skip(true);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Deliver VRF randomness for a pool sitting in Pending, locking its
    ///      rotation order and flipping it Active (mirrors the coordinator).
    function _fulfill(PotPool pool) internal {
        uint256 reqId = pool.vrfRequestId();
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256(abi.encode(reqId, block.timestamp)));
        vrf.fulfillRandomWordsWithOverride(reqId, address(pool), words);
    }

    function _isPermutationOf2(address[] memory order, address a, address b) internal pure returns (bool) {
        if (order.length != 2) return false;
        return (order[0] == a && order[1] == b) || (order[0] == b && order[1] == a);
    }

    function _form2(address a, address b) internal returns (PotPool pool) {
        vm.prank(a);
        pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0, false));
        vm.prank(a);
        pool.invite(b);
        vm.prank(b);
        pool.join(); // fills at capacity -> requests randomness
        _fulfill(pool); // deliver VRF -> Active
    }

    function _form3(address a, address b, address c) internal returns (PotPool pool) {
        vm.prank(a);
        pool = PotPool(factory.createPool(CONTRIB, 7, 3, false, 0, false));
        vm.startPrank(a);
        pool.invite(b);
        pool.invite(c);
        vm.stopPrank();
        vm.prank(b);
        pool.join();
        vm.prank(c);
        pool.join(); // fills at capacity -> requests randomness
        _fulfill(pool); // deliver VRF -> Active
    }

    function _contribute(PotPool pool, address who) internal {
        vm.startPrank(who);
        usdc.approve(address(pool), CONTRIB);
        pool.contribute();
        vm.stopPrank();
    }

    /// Form a PUBLIC pool with every member staked, fulfill VRF, and return it
    /// Active. who[0] is the creator (stakes last, which triggers the start).
    function _formPublicStaked(address[] memory who) internal returns (PotPool pool) {
        vm.prank(who[0]);
        pool = PotPool(factory.createPool(CONTRIB, 7, uint8(who.length), true, 0, false));
        for (uint256 i = 1; i < who.length; i++) {
            vm.startPrank(who[i]);
            usdc.approve(address(pool), CONTRIB); // stake approval
            pool.join();                          // pulls the stake atomically
            vm.stopPrank();
        }
        vm.startPrank(who[0]);
        usdc.approve(address(pool), CONTRIB);
        pool.stake();                             // creator stakes -> begins the pool (Pending)
        vm.stopPrank();
        _fulfill(pool);                           // VRF -> Active
    }

    /// Contribute for every current member each round until the pool completes
    /// (no defaults — everyone pays on time, so nobody is ejected).
    function _driveToComplete(PotPool pool) internal {
        for (uint256 g = 0; g < 100; g++) {
            if (uint8(pool.state()) != uint8(PotPool.PoolState.Active)) break;
            uint8 round = pool.currentRound();
            uint256 n = pool.memberCount();
            for (uint256 i = 0; i < n; i++) {
                if (uint8(pool.state()) != uint8(PotPool.PoolState.Active)) break;
                address m = pool.members(i);
                if (!pool.contributed(round, m)) _contribute(pool, m);
            }
        }
    }
}
