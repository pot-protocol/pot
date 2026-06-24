// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import "./PotScore.sol";

/// @title PotPool
/// @notice One deployed instance per savings circle. It enforces the entire
///         rotating-savings lifecycle on-chain: members join, a rotation order
///         is locked at start, each round collects an equal contribution from
///         everyone and releases the full pot to that round's recipient, late
///         members are ejected, and the circle closes clean once everyone has
///         received once.
///
/// @dev    The contract IS the trust layer. No member, not even the creator,
///         can change the rotation order, skip a recipient, or withhold a
///         payout once the pool is Active. USDC moves only along the paths
///         encoded here.
contract PotPool is VRFConsumerBaseV2Plus {
    IERC20 public immutable usdc;
    PotScore public immutable scoreContract;
    address public immutable protocolTreasury;
    address public immutable creator;

    uint256 public immutable contributionAmount; // in USDC base units (6 decimals)
    uint8 public immutable intervalDays;         // 7 (weekly) or 30 (monthly)
    uint8 public immutable maxMembers;           // 2–10
    bool public immutable isPublic;              // open to stranger pools vs invite-only
    uint16 public immutable minScore;            // Pot Score gate for public pools
    uint256 public immutable formingDeadline;    // pool must fill (or be started) before this; else cancellable

    // --- Chainlink VRF v2.5 config (passed in by the factory at deploy) ---
    bytes32 public immutable vrfKeyHash;            // gas lane
    uint256 public immutable vrfSubId;              // the factory's funded subscription
    uint32  public immutable vrfCallbackGasLimit;   // must cover the shuffle + per-member score hook
    uint16  public immutable vrfRequestConfirmations;
    bool    public immutable vrfNativePayment;      // pay VRF in native (ETH) vs LINK

    uint16 public constant PROTOCOL_FEE_BPS = 0; // 0% — protocol takes nothing; you put in $X, you get back $X
    uint48 public constant GRACE_PERIOD = 48 hours;
    uint48 public constant FORMING_WINDOW = 7 days; // lobby lifetime before a stuck pool can be cancelled
    uint48 public constant RANDOMNESS_RETRY_WINDOW = 1 days; // after this, a stuck VRF request can be reissued

    // `Pending` is appended (not inserted) so the existing numeric values of
    // Forming/Active/Complete/Cancelled stay stable for any consumer reading
    // `state()`. A pool sits in `Pending` only between "roster locked" and the
    // VRF callback that locks the rotation order.
    enum PoolState { Forming, Active, Complete, Cancelled, Pending }
    PoolState public state;

    uint256 public vrfRequestId;          // current/last VRF request awaiting fulfillment
    uint256 public randomnessRequestedAt; // when the pending request went out (retry clock)

    address[] public members;        // live roster (ejections remove entries)
    address[] public rotationOrder;  // payout order, locked at start, never mutated
    mapping(address => bool) public isMember;
    mapping(address => bool) public hasInvite;
    mapping(address => bool) public refundClaimed; // guards against double refunds after a cancellation

    uint8 public currentRound;
    uint256 public roundDeadline;
    mapping(uint8 => mapping(address => bool)) public contributed;

    event MemberJoined(address indexed member);
    event RotationRequested(uint256 indexed requestId);
    event RotationRetried(uint256 indexed oldRequestId, uint256 indexed newRequestId);
    event PoolStarted(address[] rotationOrder);
    event ContributionReceived(address indexed member, uint8 round);
    event PotPaid(address indexed recipient, uint8 round, uint256 amount);
    event MemberEjected(address indexed member, uint8 round);
    event PoolComplete();
    event PoolStartedEarly(uint8 memberCount);
    event PoolCancelled();
    event RefundClaimed(address indexed member);

    constructor(
        address _creator,
        uint256 _contributionAmount,
        uint8 _intervalDays,
        uint8 _maxMembers,
        bool _isPublic,
        uint16 _minScore,
        address _scoreContract,
        address _treasury,
        address _vrfCoordinator,
        bytes32 _vrfKeyHash,
        uint256 _vrfSubId,
        uint32 _vrfCallbackGasLimit,
        uint16 _vrfRequestConfirmations,
        bool _vrfNativePayment
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        creator = _creator;
        contributionAmount = _contributionAmount;
        intervalDays = _intervalDays;
        maxMembers = _maxMembers;
        isPublic = _isPublic;
        minScore = _minScore;
        scoreContract = PotScore(_scoreContract);
        protocolTreasury = _treasury;
        vrfKeyHash = _vrfKeyHash;
        vrfSubId = _vrfSubId;
        vrfCallbackGasLimit = _vrfCallbackGasLimit;
        vrfRequestConfirmations = _vrfRequestConfirmations;
        vrfNativePayment = _vrfNativePayment;
        usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913); // USDC on Base mainnet
        state = PoolState.Forming;
        formingDeadline = block.timestamp + FORMING_WINDOW;
        _join(_creator);
    }

    // ---------------------------------------------------------------------
    // Forming
    // ---------------------------------------------------------------------

    /// @notice Creator whitelists an address for an invite-only (private) pool.
    function invite(address addr) external {
        require(msg.sender == creator, "Only creator invites");
        require(state == PoolState.Forming, "Not forming");
        hasInvite[addr] = true;
    }

    /// @notice Join a forming pool. Public pools gate on Pot Score; private
    ///         pools gate on an invite from the creator. The pool auto-starts
    ///         once the roster is full.
    function join() external {
        require(state == PoolState.Forming, "Not forming");
        require(members.length < maxMembers, "Pool full");
        if (isPublic) {
            require(scoreContract.getScore(msg.sender) >= minScore, "Score too low");
        } else {
            require(hasInvite[msg.sender] || msg.sender == creator, "No invite");
        }
        _join(msg.sender);
        if (members.length == maxMembers) {
            _requestRotation();
        }
    }

    function _join(address addr) internal {
        require(!isMember[addr], "Already member");
        isMember[addr] = true;
        members.push(addr);
        emit MemberJoined(addr);
    }

    /// @dev Two-phase start, phase 1. Park the pool in `Pending` and ask
    ///      Chainlink VRF for one verifiable random word. The rotation order is
    ///      deliberately NOT computed here: under the old synchronous shuffle the
    ///      transaction that triggered the start (the final joiner, or the
    ///      creator via `startEarly`) could read `block.prevrandao` in-block,
    ///      simulate the resulting order, and grind submissions until it landed
    ///      an early slot. Sourcing the seed from VRF — delivered in a *later*
    ///      block the trigger cannot influence — removes that grind. No member
    ///      funds are held while `Pending` (`contribute` requires `Active`), so a
    ///      pool awaiting fulfillment has nothing at risk.
    function _requestRotation() internal {
        state = PoolState.Pending;
        randomnessRequestedAt = block.timestamp;
        vrfRequestId = _sendRandomnessRequest();
        emit RotationRequested(vrfRequestId);
    }

    /// @dev The single VRF request site, shared by the initial start and the
    ///      stuck-request retry so the request parameters can never drift apart.
    function _sendRandomnessRequest() private returns (uint256) {
        return s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: vrfNativePayment})
                )
            })
        );
    }

    /// @dev Two-phase start, phase 2 — the VRF callback. Locks the rotation
    ///      order with a Fisher-Yates shuffle seeded by the verifiable random
    ///      word, arms round 0, and flips the pool `Active`. Request-scoped and
    ///      idempotent: a callback for a superseded (retried) request, or any
    ///      callback once the pool is no longer `Pending`, is ignored rather than
    ///      reverted — so a late or stale fulfillment can never re-roll an order
    ///      that is already locked. `rawFulfillRandomWords` in the base contract
    ///      guarantees only the VRF coordinator can reach this.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        if (state != PoolState.Pending || requestId != vrfRequestId) {
            return;
        }
        uint256 seed = randomWords[0];
        rotationOrder = members;
        for (uint256 i = rotationOrder.length - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encodePacked(seed, i))) % (i + 1);
            (rotationOrder[i], rotationOrder[j]) = (rotationOrder[j], rotationOrder[i]);
        }
        state = PoolState.Active;
        currentRound = 0;
        roundDeadline = block.timestamp + (uint256(intervalDays) * 1 days);
        scoreContract.onPoolStarted(members);
        emit PoolStarted(rotationOrder);
    }

    /// @notice Permissionless escape hatch for a VRF request that never gets
    ///         fulfilled — e.g. the protocol's subscription ran out of LINK/native
    ///         and the coordinator dropped the callback. After
    ///         `RANDOMNESS_RETRY_WINDOW` anyone may reissue the request; it costs
    ///         only a fresh VRF fee, and because no member funds are held while
    ///         `Pending`, this can't be abused to move anyone's money. Retiring
    ///         the old `vrfRequestId` makes its (now stale) callback a no-op.
    function retryRotation() external {
        require(state == PoolState.Pending, "Not pending");
        require(
            block.timestamp >= randomnessRequestedAt + RANDOMNESS_RETRY_WINDOW,
            "Retry too soon"
        );
        uint256 oldId = vrfRequestId;
        randomnessRequestedAt = block.timestamp;
        vrfRequestId = _sendRandomnessRequest();
        emit RotationRetried(oldId, vrfRequestId);
    }

    /// @notice Creator kicks off an under-filled pool without waiting for every
    ///         seat. Only valid while `Forming` and only once at least two
    ///         members are in, so the smallest viable circle (a pair) can run.
    ///         Reuses `_requestRotation` verbatim — same VRF request, same
    ///         two-phase lock — so an early start and a full-capacity start are
    ///         mechanically identical, randomness path included.
    function startEarly() external {
        require(msg.sender == creator, "Only creator");
        require(state == PoolState.Forming, "Not forming");
        require(members.length >= 2, "Need 2+ members");
        emit PoolStartedEarly(uint8(members.length));
        _requestRotation();
    }

    /// @notice Permissionless escape hatch for a pool that never filled. Once the
    ///         forming window has elapsed with the roster still incomplete,
    ///         anyone may cancel it so members aren't stranded in `Forming`
    ///         forever. Flips state to `Cancelled`; members then call
    ///         `claimRefund` to recover any stake.
    /// @dev    CEI: the only state change (`state`) is written before the event;
    ///         there are no external calls here, so there is no reentrancy
    ///         surface to guard.
    function cancelIfExpired() external {
        require(state == PoolState.Forming, "Not forming");
        require(block.timestamp >= formingDeadline, "Not expired");
        state = PoolState.Cancelled;
        emit PoolCancelled();
    }

    /// @notice After a pool is `Cancelled`, a member reclaims their stake deposit.
    /// @dev    Stake deposits are a v1 feature (see ARCHITECTURE.md "Known gaps":
    ///         stake deposit / disband refund accounting) and are not yet held
    ///         on-chain, so there is nothing to transfer today — this is a stub
    ///         that records the claim and emits `RefundClaimed`. The
    ///         `refundClaimed` guard and the CEI ordering are written now so the
    ///         transfer can be dropped in later without re-architecting: the
    ///         effect (marking the claim) already precedes the (future) interaction.
    function claimRefund() external {
        require(state == PoolState.Cancelled, "Not cancelled");
        require(isMember[msg.sender], "Not a member");
        require(!refundClaimed[msg.sender], "Already refunded");

        // Checks-Effects-Interactions: set the guard before any (future) transfer.
        refundClaimed[msg.sender] = true;
        // Stake-deposit refund transfer goes here once stakes are held on-chain (v1).
        emit RefundClaimed(msg.sender);
    }

    // ---------------------------------------------------------------------
    // Active rounds
    // ---------------------------------------------------------------------

    /// @notice Pay this round's contribution. Caller must have approved this
    ///         contract for `contributionAmount` USDC beforehand. On-time vs.
    ///         grace-period status is recorded to the member's Pot Score.
    ///         The final contributor of a round triggers settlement automatically.
    function contribute() external {
        require(state == PoolState.Active, "Not active");
        require(isMember[msg.sender], "Not a member");
        require(!contributed[currentRound][msg.sender], "Already contributed");
        require(block.timestamp <= roundDeadline + GRACE_PERIOD, "Grace period passed");

        contributed[currentRound][msg.sender] = true;
        // CEI: state set above before the external token pull.
        require(
            usdc.transferFrom(msg.sender, address(this), contributionAmount),
            "USDC transfer failed"
        );
        scoreContract.onContribution(msg.sender, block.timestamp <= roundDeadline);
        emit ContributionReceived(msg.sender, currentRound);
        _trySettle();
    }

    /// @dev If every live member has contributed this round, settle immediately.
    function _trySettle() internal {
        uint256 paidCount = 0;
        for (uint256 i = 0; i < members.length; i++) {
            if (contributed[currentRound][members[i]]) paidCount++;
        }
        if (members.length > 0 && paidCount == members.length) {
            _payout();
        }
    }

    /// @notice Permissionless settlement after the grace period: anyone may call
    ///         this to eject the round's defaulters and release the pot. This is
    ///         how a round closes if not everyone paid in time.
    function settle() external {
        require(state == PoolState.Active, "Not active");
        require(block.timestamp > roundDeadline + GRACE_PERIOD, "Grace not expired");
        _ejectMissers();
        _payout();
    }

    /// @dev Eject every member who did not contribute this round, leaving a
    ///      permanent Pot Score mark on each. Swap-and-pop keeps the loop O(n);
    ///      `i--` re-checks the swapped-in entry.
    function _ejectMissers() internal {
        for (uint256 i = 0; i < members.length; i++) {
            address m = members[i];
            if (!contributed[currentRound][m]) {
                isMember[m] = false;
                scoreContract.onMiss(m);
                emit MemberEjected(m, currentRound);
                members[i] = members[members.length - 1];
                members.pop();
                if (i == 0) break; // avoid underflow when index 0 was the last entry
                i--;
            }
        }
    }

    /// @dev Release the pot to this round's recipient, skipping any recipient who
    ///      has been ejected, then advance the round (or complete the pool).
    function _payout() internal {
        // Advance past ejected recipients so we never pay a wallet that left.
        address recipient = rotationOrder[currentRound];
        while (!isMember[recipient] && currentRound < rotationOrder.length - 1) {
            currentRound++;
            recipient = rotationOrder[currentRound];
        }

        // GUARD: if a full wipeout left no live members, there is no one to pay.
        // Cancel the pool; net funds (if any) are recoverable in v0.2 reconcile.
        // See ARCHITECTURE.md "Known gaps": disband/refund accounting.
        if (members.length == 0 || !isMember[recipient]) {
            state = PoolState.Cancelled;
            return;
        }

        uint256 pot = usdc.balanceOf(address(this));
        uint256 fee = (pot * PROTOCOL_FEE_BPS) / 10_000;
        uint256 payout = pot - fee;

        // Checks-Effects-Interactions: advance all state before transfers.
        scoreContract.onPayout(recipient);
        emit PotPaid(recipient, currentRound, payout);
        currentRound++;

        if (currentRound >= rotationOrder.length) {
            state = PoolState.Complete;
            scoreContract.onPoolComplete(members);
            emit PoolComplete();
        } else {
            roundDeadline = block.timestamp + (uint256(intervalDays) * 1 days);
        }

        // Interactions last. USDC is a known, non-reentrant standard token on
        // Base; even so, all storage is already finalized above.
        if (fee > 0) {
            require(usdc.transfer(protocolTreasury, fee), "Fee transfer failed");
        }
        require(usdc.transfer(recipient, payout), "Payout transfer failed");
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function memberCount() external view returns (uint256) {
        return members.length;
    }

    function getRotationOrder() external view returns (address[] memory) {
        return rotationOrder;
    }
}
