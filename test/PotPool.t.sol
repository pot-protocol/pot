// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
/// @notice Exercises the full lifecycle of a Pot circle. The happy-path tests
///         below are real and should pass against the contracts as written.
///         The `testTODO_*` functions are intentional stubs that name the edge
///         cases an audit must cover before mainnet — each maps to an item in
///         ARCHITECTURE.md "Known gaps / audit targets".
///
/// @dev    IMPORTANT TEST-HARNESS NOTE: PotPool hardcodes the Base mainnet USDC
///         address in its constructor. To test against MockUSDC you must either
///         (a) `vm.etch` the mock's runtime bytecode at that address, or
///         (b) refactor PotPool to take the USDC address as a constructor arg
///         (recommended — see ARCHITECTURE.md). The setUp below uses approach
///         (a) so the suite runs without modifying the contract.
contract PotPoolTest is Test {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    MockUSDC usdc;
    PotScore score;
    PotFactory factory;

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

        score = new PotScore();
        factory = new PotFactory(address(score), treasury);
        // Factory must own the score registry to authorize pools (deploy invariant).
        score.transferOwnership(address(factory));

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
        address poolAddr = factory.createPool(CONTRIB, 7, 2, false, 0);

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
        factory.createPool(24e6, 7, 2, false, 0);
    }

    function test_PrivatePool_RequiresInvite() public {
        vm.prank(alice);
        PotPool pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0));

        vm.prank(bob);
        vm.expectRevert(bytes("No invite"));
        pool.join();

        vm.prank(alice);
        pool.invite(bob);

        vm.prank(bob);
        pool.join(); // fills the 2-person pool and auto-starts

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

    function test_ProtocolFee_IsOnePercentOfPot() public {
        PotPool pool = _form2(alice, bob);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        _contribute(pool, alice);
        _contribute(pool, bob); // settles round 0, pot = 2 * $100 = $200

        uint256 feeTaken = usdc.balanceOf(treasury) - treasuryBefore;
        assertEq(feeTaken, (CONTRIB * 2 * 100) / 10_000); // 1% of $200 = $2
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
        PotPool pool = _form2(alice, bob);
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
    // TODO: audit-target edge cases (stubs — implement before mainnet)
    // ------------------------------------------------------------------

    /// Gap: full-wipeout round. If EVERY remaining member misses the same round,
    /// `_ejectMissers` empties `members` and `_payout` must cancel cleanly
    /// rather than revert or pay a ghost. Assert state == Cancelled and no
    /// USDC is sent to a non-member.
    function testTODO_AllMembersMiss_CancelsCleanly() public {
        vm.skip(true);
    }

    /// Gap: weak randomness. `_start` uses block.prevrandao. A validator/builder
    /// can bias rotation order. This test should document the bias surface and
    /// will be replaced by a Chainlink VRF integration test before mainnet.
    function testTODO_RotationRandomness_VRF() public {
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

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _form2(address a, address b) internal returns (PotPool pool) {
        vm.prank(a);
        pool = PotPool(factory.createPool(CONTRIB, 7, 2, false, 0));
        vm.prank(a);
        pool.invite(b);
        vm.prank(b);
        pool.join(); // auto-starts at capacity
    }

    function _form3(address a, address b, address c) internal returns (PotPool pool) {
        vm.prank(a);
        pool = PotPool(factory.createPool(CONTRIB, 7, 3, false, 0));
        vm.startPrank(a);
        pool.invite(b);
        pool.invite(c);
        vm.stopPrank();
        vm.prank(b);
        pool.join();
        vm.prank(c);
        pool.join(); // auto-starts at capacity
    }

    function _contribute(PotPool pool, address who) internal {
        vm.startPrank(who);
        usdc.approve(address(pool), CONTRIB);
        pool.contribute();
        vm.stopPrank();
    }
}
