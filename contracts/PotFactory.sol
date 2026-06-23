// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

    constructor(address _scoreContract, address _treasury) {
        require(_scoreContract != address(0) && _treasury != address(0), "Zero address");
        scoreContract = PotScore(_scoreContract);
        protocolTreasury = _treasury;
    }

    /// @notice Deploy a new savings circle.
    /// @param contributionAmount Per-round contribution in USDC base units (>= $25).
    /// @param intervalDays       7 for weekly, 30 for monthly.
    /// @param memberCount        Target roster size, 2–10.
    /// @param isPublic           Open to score-gated strangers, or invite-only.
    /// @param minScoreRequired   Pot Score gate for public pools.
    function createPool(
        uint256 contributionAmount,
        uint8 intervalDays,
        uint8 memberCount,
        bool isPublic,
        uint16 minScoreRequired
    ) external returns (address) {
        require(contributionAmount >= 25e6, "Minimum $25");
        require(memberCount >= 2 && memberCount <= 10, "2-10 members");
        require(intervalDays == 7 || intervalDays == 30, "Weekly or monthly");
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
            protocolTreasury
        );

        // Critical wiring: let this pool record reputation. Without this, every
        // score hook the pool fires would revert and the pool could never start.
        scoreContract.authorizePool(address(pool));

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
