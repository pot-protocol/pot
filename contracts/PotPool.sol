// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
contract PotPool {
    IERC20 public immutable usdc;
    PotScore public immutable scoreContract;
    address public immutable protocolTreasury;
    address public immutable creator;

    uint256 public immutable contributionAmount; // in USDC base units (6 decimals)
    uint8 public immutable intervalDays;         // 7 (weekly) or 30 (monthly)
    uint8 public immutable maxMembers;           // 2–10
    bool public immutable isPublic;              // open to stranger pools vs invite-only
    uint16 public immutable minScore;            // Pot Score gate for public pools

    uint16 public constant PROTOCOL_FEE_BPS = 100; // 1%
    uint48 public constant GRACE_PERIOD = 48 hours;

    enum PoolState { Forming, Active, Complete, Cancelled }
    PoolState public state;

    address[] public members;        // live roster (ejections remove entries)
    address[] public rotationOrder;  // payout order, locked at start, never mutated
    mapping(address => bool) public isMember;
    mapping(address => bool) public hasInvite;

    uint8 public currentRound;
    uint256 public roundDeadline;
    mapping(uint8 => mapping(address => bool)) public contributed;

    event MemberJoined(address indexed member);
    event PoolStarted(address[] rotationOrder);
    event ContributionReceived(address indexed member, uint8 round);
    event PotPaid(address indexed recipient, uint8 round, uint256 amount);
    event MemberEjected(address indexed member, uint8 round);
    event PoolComplete();

    constructor(
        address _creator,
        uint256 _contributionAmount,
        uint8 _intervalDays,
        uint8 _maxMembers,
        bool _isPublic,
        uint16 _minScore,
        address _scoreContract,
        address _treasury
    ) {
        creator = _creator;
        contributionAmount = _contributionAmount;
        intervalDays = _intervalDays;
        maxMembers = _maxMembers;
        isPublic = _isPublic;
        minScore = _minScore;
        scoreContract = PotScore(_scoreContract);
        protocolTreasury = _treasury;
        usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913); // USDC on Base mainnet
        state = PoolState.Forming;
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
            _start();
        }
    }

    function _join(address addr) internal {
        require(!isMember[addr], "Already member");
        isMember[addr] = true;
        members.push(addr);
        emit MemberJoined(addr);
    }

    /// @dev Lock the rotation order with a Fisher-Yates shuffle and arm round 0.
    ///      v0.1 randomness source is block.prevrandao (see ARCHITECTURE.md
    ///      "Known gaps": replace with Chainlink VRF before mainnet).
    function _start() internal {
        rotationOrder = members;
        for (uint256 i = rotationOrder.length - 1; i > 0; i--) {
            uint256 j = uint256(
                keccak256(abi.encodePacked(block.timestamp, block.prevrandao, i))
            ) % (i + 1);
            (rotationOrder[i], rotationOrder[j]) = (rotationOrder[j], rotationOrder[i]);
        }
        state = PoolState.Active;
        currentRound = 0;
        roundDeadline = block.timestamp + (uint256(intervalDays) * 1 days);
        scoreContract.onPoolStarted(members);
        emit PoolStarted(rotationOrder);
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
