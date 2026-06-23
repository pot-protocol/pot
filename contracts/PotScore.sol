// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PotScore
/// @notice Soulbound (non-transferable) ERC-721 reputation token. One token per
///         wallet, permanent. It records a member's demonstrated reliability
///         across every Pot circle they have ever joined. The score is the only
///         thing being "built" by the protocol: it is not granted by any
///         institution and it cannot be bought or transferred. You earn it by
///         showing up.
///
/// @dev    The token is made soulbound by overriding `_update` to reject any
///         transfer between two non-zero addresses (mint and burn still work).
///         Score-mutating hooks (`onContribution`, `onMiss`, etc.) are callable
///         only by pools that the contract owner has authorized via
///         `authorizePool` — in production this authorization is performed by
///         the PotFactory immediately after it deploys each pool.
contract PotScore is ERC721, Ownable {
    /// @notice The raw reliability record for a single wallet. The composite
    ///         0–1000 score is derived from these fields in `getScore`.
    struct Score {
        uint16 poolsCompleted; // circles seen all the way through
        uint16 totalRounds;    // contribution rounds participated in
        uint16 onTimeRounds;   // rounds contributed before the deadline
        uint8 missedRounds;    // rounds missed (permanent — never decremented)
        uint8 currentStreak;   // consecutive on-time rounds, reset by a miss
        uint8 bestStreak;      // highest streak ever reached
    }

    /// @notice wallet => reliability record
    mapping(address => Score) public scores;
    /// @notice wallet => soulbound token id (0 means not yet minted)
    mapping(address => uint256) public tokenOf;
    /// @notice pool address => may mutate scores
    mapping(address => bool) public authorizedPools;

    uint256 private _nextTokenId = 1;

    event ScoreUpdated(address indexed wallet, uint16 poolsCompleted, uint8 missedRounds);
    event PoolAuthorized(address indexed pool);

    constructor() ERC721("Pot Score", "POT-REP") Ownable(msg.sender) {}

    // ---------------------------------------------------------------------
    // Authorization
    // ---------------------------------------------------------------------

    /// @notice Grant a pool permission to mutate scores. Called by the owner,
    ///         which is the PotFactory in production deployments.
    function authorizePool(address pool) external onlyOwner {
        authorizedPools[pool] = true;
        emit PoolAuthorized(pool);
    }

    modifier onlyPool() {
        require(authorizedPools[msg.sender], "Not authorized pool");
        _;
    }

    // ---------------------------------------------------------------------
    // Soulbound enforcement
    // ---------------------------------------------------------------------

    /// @dev Block transfers between two real addresses. Minting (from == 0) and
    ///      burning (to == 0) remain possible; everything else reverts.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        require(from == address(0) || to == address(0), "Soulbound: non-transferable");
        return super._update(to, tokenId, auth);
    }

    /// @dev Lazily mint a wallet's soulbound token the first time it touches a pool.
    function _ensureMinted(address wallet) internal {
        if (tokenOf[wallet] == 0) {
            uint256 id = _nextTokenId++;
            tokenOf[wallet] = id;
            _mint(wallet, id);
        }
    }

    // ---------------------------------------------------------------------
    // Lifecycle hooks (pool-only)
    // ---------------------------------------------------------------------

    /// @notice Called when a pool starts; ensures every member has a token.
    function onPoolStarted(address[] calldata members) external onlyPool {
        for (uint256 i = 0; i < members.length; i++) {
            _ensureMinted(members[i]);
        }
    }

    /// @notice Record a contribution. `onTime` distinguishes within-deadline
    ///         contributions (which build streak and on-time rate) from
    ///         grace-period contributions (which count as a round but not on time).
    function onContribution(address wallet, bool onTime) external onlyPool {
        _ensureMinted(wallet);
        Score storage s = scores[wallet];
        s.totalRounds++;
        if (onTime) {
            s.onTimeRounds++;
            s.currentStreak++;
            if (s.currentStreak > s.bestStreak) s.bestStreak = s.currentStreak;
        } else {
            s.currentStreak = 0;
        }
    }

    /// @notice Record a missed round. This leaves a permanent mark: missedRounds
    ///         is never decremented, anywhere, by any code path.
    function onMiss(address wallet) external onlyPool {
        _ensureMinted(wallet);
        Score storage s = scores[wallet];
        s.missedRounds++;
        s.currentStreak = 0;
        emit ScoreUpdated(wallet, s.poolsCompleted, s.missedRounds);
    }

    /// @notice Reserved hook fired when a wallet receives a payout. No score
    ///         effect today — receiving the pot is neutral, since the trust was
    ///         already demonstrated by the people who funded it. Kept for
    ///         forward compatibility and event symmetry.
    function onPayout(address wallet) external onlyPool {}

    /// @notice Credit every member with a completed pool when a circle closes clean.
    function onPoolComplete(address[] calldata members) external onlyPool {
        for (uint256 i = 0; i < members.length; i++) {
            scores[members[i]].poolsCompleted++;
            emit ScoreUpdated(members[i], scores[members[i]].poolsCompleted, scores[members[i]].missedRounds);
        }
    }

    // ---------------------------------------------------------------------
    // Score readout
    // ---------------------------------------------------------------------

    /// @notice Composite reliability score, 0–1000.
    /// @dev    score = poolsCompleted*50 + onTimeRate*4 + bestStreak*10 - missedRounds*75
    ///         The subtraction is computed against a non-negative base, then the
    ///         result is clamped, so it can never underflow.
    function getScore(address wallet) external view returns (uint16) {
        Score memory s = scores[wallet];
        if (s.totalRounds == 0) return 0;

        uint256 onTimeRate = (uint256(s.onTimeRounds) * 100) / s.totalRounds; // 0–100
        uint256 positive = (uint256(s.poolsCompleted) * 50)
            + (onTimeRate * 4)
            + (uint256(s.bestStreak) * 10);
        uint256 penalty = uint256(s.missedRounds) * 75;

        if (penalty >= positive) return 0;
        uint256 score = positive - penalty;
        if (score > 1000) return 1000;
        return uint16(score);
    }
}
