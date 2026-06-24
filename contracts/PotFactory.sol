// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import "./PotPool.sol";
import "./PotScore.sol";

/// @title PotFactory
/// @notice The single entry point for creating circles. It deploys every
///         PotPool, authorizes each new pool to write to the shared PotScore
///         registry, and keeps an on-chain index of all pools (and pools by
///         creator) so the frontend can discover them.
///
/// @dev    DEPLOYMENT INVARIANT: the factory must be the `owner` of the
///         PotScore contract, because authorizing a pool calls
///         `scoreContract.authorizePool(...)`, which is `onlyOwner`. The deploy
///         script transfers PotScore ownership to the factory after both are
///         live (see scripts/deploy.js). If ownership is not transferred,
///         `createPool` will revert at the authorize step — a fail-closed
///         posture, which is the safe failure mode.
contract PotFactory {
    PotScore public immutable scoreContract;
    address public immutable protocolTreasury;
    address public immutable usdc; // the network's USDC, passed to every pool (was hardcoded in PotPool)

    // --- Chainlink VRF v2.5 ---
    // The factory owns ONE subscription (created in the constructor) and adds
    // every pool it deploys as a consumer. Fund this subscription on the
    // coordinator (LINK or native, matching `vrfNativePayment`) before pools can
    // start; at PROTOCOL_FEE_BPS = 0 the protocol/treasury subsidizes it, which
    // keeps the "put in $X, get back $X" promise intact. Switching to a per-pool
    // VRF fee later is a localized change (a fee constant + a collection step),
    // not a re-architecture.
    IVRFCoordinatorV2Plus public immutable vrfCoordinator;
    uint256 public immutable vrfSubId;
    bytes32 public immutable vrfKeyHash;
    uint32  public immutable vrfCallbackGasLimit;
    uint16  public immutable vrfRequestConfirmations;
    bool    public immutable vrfNativePayment;

    address[] public allPools;
    mapping(address => address[]) public poolsByCreator;
    mapping(address => bool) public isPool; // reverse lookup for off-chain trust checks

    event PoolCreated(
        address indexed pool,
        address indexed creator,
        uint256 contributionAmount,
        uint8 intervalDays,
        uint8 memberCount
    );

    constructor(
        address _scoreContract,
        address _treasury,
        address _usdc,
        address _vrfCoordinator,
        bytes32 _vrfKeyHash,
        uint32 _vrfCallbackGasLimit,
        uint16 _vrfRequestConfirmations,
        bool _vrfNativePayment
    ) {
        require(_scoreContract != address(0) && _treasury != address(0), "Zero address");
        require(_usdc != address(0), "Zero USDC");
        require(_vrfCoordinator != address(0), "Zero VRF coordinator");
        scoreContract = PotScore(_scoreContract);
        protocolTreasury = _treasury;
        usdc = _usdc;
        vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        vrfKeyHash = _vrfKeyHash;
        vrfCallbackGasLimit = _vrfCallbackGasLimit;
        vrfRequestConfirmations = _vrfRequestConfirmations;
        vrfNativePayment = _vrfNativePayment;
        // Create the shared subscription; the factory is its owner, which is what
        // lets `createPool` authorize each new pool as a VRF consumer.
        vrfSubId = IVRFCoordinatorV2Plus(_vrfCoordinator).createSubscription();
    }

    /// @notice Deploy a new savings circle.
    /// @param contributionAmount Per-round contribution in USDC base units (>= $25).
    /// @param intervalDays       7 for weekly, 30 for monthly.
    /// @param memberCount        Target roster size, 2–10.
    /// @param isPublic           Open to score-gated strangers, or invite-only.
    /// @param minScoreRequired   Pot Score gate for public pools.
    /// @param useFixedOrder      Private-pool option: creator-set/join payout order
    ///                           (skips VRF). Rejected for public pools.
    function createPool(
        uint256 contributionAmount,
        uint8 intervalDays,
        uint8 memberCount,
        bool isPublic,
        uint16 minScoreRequired,
        bool useFixedOrder
    ) external returns (address) {
        require(contributionAmount >= 25e6, "Minimum $25");
        require(memberCount >= 2 && memberCount <= 10, "2-10 members");
        require(intervalDays == 7 || intervalDays == 30, "Weekly or monthly");
        require(!useFixedOrder || !isPublic, "Public pools must use random ordering");
        if (isPublic) {
            require(
                scoreContract.getScore(msg.sender) >= minScoreRequired,
                "Score too low to create public pool"
            );
        }

        PotPool pool = new PotPool(
            msg.sender,
            contributionAmount,
            intervalDays,
            memberCount,
            isPublic,
            minScoreRequired,
            address(scoreContract),
            protocolTreasury,
            usdc,
            address(vrfCoordinator),
            vrfKeyHash,
            vrfSubId,
            vrfCallbackGasLimit,
            vrfRequestConfirmations,
            vrfNativePayment,
            useFixedOrder
        );

        // Critical wiring: let this pool record reputation. Without this, every
        // score hook the pool fires would revert and the pool could never start.
        scoreContract.authorizePool(address(pool));

        // VRF wiring: authorize this pool to draw from the factory's subscription.
        // The factory is the subscription owner, so only it can add consumers.
        vrfCoordinator.addConsumer(vrfSubId, address(pool));

        allPools.push(address(pool));
        poolsByCreator[msg.sender].push(address(pool));
        isPool[address(pool)] = true;

        emit PoolCreated(address(pool), msg.sender, contributionAmount, intervalDays, memberCount);
        return address(pool);
    }

    function totalPools() external view returns (uint256) {
        return allPools.length;
    }

    function getPoolsByCreator(address creator) external view returns (address[] memory) {
        return poolsByCreator[creator];
    }
}
