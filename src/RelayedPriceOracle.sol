// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./IPriceOracle.sol";

/// @title RelayedPriceOracle
/// @notice Chainlink prices from Base, relayed to Horizen by a k-of-n set of relayers.
///
///         Each relayer reads the same Chainlink round on Base (roundId, answer, updatedAt)
///         and submits it here. Because every honest relayer reads the SAME source data,
///         we require an EXACT match: a price is accepted once `quorum` distinct relayers
///         submitted identical (asset, roundId, answer, updatedAt). No median needed.
///
///         CIRCUIT BREAKER: if an agreed round moves the price more than `maxDeviationBps`
///         versus the last trusted price, the asset is TRIPPED instead of reverting:
///         the round is parked as `pending`, and getPrice() reverts until the owner
///         reviews it. This fails closed: the pool stops using the old price immediately,
///         instead of keeping it alive until it goes stale.
///
///         TRUST MODEL: this contract cannot see Base. It trusts that at least `quorum`
///         relayers are honest. Keep keys on separate infrastructure; owner = multisig.
contract RelayedPriceOracle is IPriceOracle, Ownable {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct AssetConfig {
        uint8 feedDecimals; // Chainlink feed decimals (8 for USD feeds)
        uint32 maxAge; // max age of the CHAINLINK update, in seconds
        uint16 maxDeviationBps; // circuit breaker: max move vs last trusted price
        bool enabled;
    }

    struct PriceData {
        uint256 price; // USD per whole token, 1e18
        uint80 roundId; // Chainlink round on Base
        uint64 updatedAt; // Chainlink's updatedAt (NOT relay time)
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    /// @dev Tolerated clock difference between Base and Horizen.
    uint256 internal constant MAX_FUTURE_DRIFT = 60;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(address relayer => bool) public isRelayer;
    uint256 public relayerCount;
    uint256 public quorum;

    /// @notice Incremented on every relayer-set or quorum change. Part of the vote key,
    ///         so votes cast under an old relayer set can never count toward a new one.
    uint256 public epoch;

    mapping(address asset => AssetConfig) public assetConfig;

    /// @notice Last TRUSTED price per asset (what getPrice returns when not tripped).
    mapping(address asset => PriceData) public latest;

    /// @notice Circuit breaker state. While true, getPrice reverts.
    mapping(address asset => bool) public tripped;

    /// @notice Newest agreed round received while tripped, awaiting owner review.
    mapping(address asset => PriceData) public pending;

    /// @dev votes[key] = number of distinct relayers that submitted exactly this data.
    mapping(bytes32 key => uint256) public votes;
    mapping(bytes32 key => mapping(address relayer => bool)) public hasVoted;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event QuorumSet(uint256 quorum);
    event AssetConfigured(address indexed asset, uint8 feedDecimals, uint32 maxAge, uint16 maxDeviationBps);
    event Submitted(address indexed asset, address indexed relayer, uint80 roundId, bytes32 key, uint256 votes);
    event PriceUpdated(address indexed asset, uint80 roundId, uint256 price, uint64 updatedAt);
    event CircuitBreakerTripped(address indexed asset, uint256 trustedPrice, uint256 newPrice, uint80 roundId);
    event PendingUpdated(address indexed asset, uint80 roundId, uint256 price, uint64 updatedAt);
    event PendingAccepted(address indexed asset, uint80 roundId, uint256 price);
    event BreakerReset(address indexed asset);

    error ZeroAddress();
    error NotRelayer(address caller);
    error AlreadyRelayer(address relayer);
    error InvalidQuorum(uint256 quorum, uint256 relayerCount);
    error InvalidConfig();
    error AssetNotEnabled(address asset);
    error AlreadyVoted(address relayer, bytes32 key);
    error InvalidAnswer(int256 answer);
    error FutureTimestamp(uint256 updatedAt, uint256 nowTs);
    error NotNewer(uint80 roundId, uint64 updatedAt, uint80 lastRoundId, uint64 lastUpdatedAt);
    error NoPrice(address asset);
    error StalePrice(address asset, uint256 updatedAt, uint256 maxAge);
    error CircuitBreakerActive(address asset);
    error NotTripped(address asset);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ---------------------------------------------------------------------
    // Admin (owner = multisig in production)
    // ---------------------------------------------------------------------

    function addRelayer(address relayer) external onlyOwner {
        if (relayer == address(0)) revert ZeroAddress();
        if (isRelayer[relayer]) revert AlreadyRelayer(relayer);
        isRelayer[relayer] = true;
        relayerCount += 1;
        epoch += 1;
        emit RelayerAdded(relayer);
    }

    function removeRelayer(address relayer) external onlyOwner {
        if (!isRelayer[relayer]) revert NotRelayer(relayer);
        if (relayerCount - 1 < quorum) revert InvalidQuorum(quorum, relayerCount - 1);
        isRelayer[relayer] = false;
        relayerCount -= 1;
        epoch += 1; // invalidates any pending votes, including the removed relayer's
        emit RelayerRemoved(relayer);
    }

    function setQuorum(uint256 newQuorum) external onlyOwner {
        if (newQuorum == 0 || newQuorum > relayerCount) revert InvalidQuorum(newQuorum, relayerCount);
        quorum = newQuorum;
        epoch += 1;
        emit QuorumSet(newQuorum);
    }

    /// @param feedDecimals    Decimals of the Chainlink feed on Base (check with `decimals()`).
    /// @param maxAge          Reject prices whose Chainlink updatedAt is older than this.
    ///                        Must exceed the feed's Chainlink heartbeat (e.g. ~24h for USDC/USD).
    /// @param maxDeviationBps Trip the breaker if one update moves the price more than this.
    ///                        Keep it loose for stablecoins: a depeg is real data, not an error.
    function configureAsset(address asset, uint8 feedDecimals, uint32 maxAge, uint16 maxDeviationBps)
        external
        onlyOwner
    {
        if (asset == address(0)) revert ZeroAddress();
        if (feedDecimals > 18 || maxAge == 0 || maxDeviationBps == 0 || maxDeviationBps > BPS) {
            revert InvalidConfig();
        }
        assetConfig[asset] = AssetConfig({
            feedDecimals: feedDecimals, maxAge: maxAge, maxDeviationBps: maxDeviationBps, enabled: true
        });
        emit AssetConfigured(asset, feedDecimals, maxAge, maxDeviationBps);
    }

    /// @notice After review: the big move was real. Promote the pending round to trusted.
    function acceptPending(address asset) external onlyOwner {
        if (!tripped[asset]) revert NotTripped(asset);
        PriceData memory p = pending[asset];
        latest[asset] = p;
        tripped[asset] = false;
        delete pending[asset];
        emit PendingAccepted(asset, p.roundId, p.price);
        emit PriceUpdated(asset, p.roundId, p.price, p.updatedAt);
    }

    /// @notice After review: the data was wrong (e.g. relayer bug). Discard pending and
    ///         resume. The old trusted price becomes usable again until it goes stale,
    ///         and the next normal round is again checked against it.
    function resetBreaker(address asset) external onlyOwner {
        if (!tripped[asset]) revert NotTripped(asset);
        tripped[asset] = false;
        delete pending[asset];
        emit BreakerReset(asset);
    }

    // ---------------------------------------------------------------------
    // Relayer submission
    // ---------------------------------------------------------------------

    /// @notice Submit one Chainlink round, exactly as read from `latestRoundData()` on Base.
    /// @return accepted True if this vote reached quorum AND the trusted price was updated.
    ///         False if still collecting votes, or if the round went to `pending` (tripped).
    function submit(address asset, uint80 roundId, int256 answer, uint64 updatedAt)
        external
        returns (bool accepted)
    {
        if (!isRelayer[msg.sender]) revert NotRelayer(msg.sender);
        AssetConfig memory cfg = assetConfig[asset];
        if (!cfg.enabled) revert AssetNotEnabled(asset);

        // Readability over a few gas: plain keccak256 instead of inline assembly.
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 key = keccak256(abi.encode(epoch, asset, roundId, answer, updatedAt));
        if (hasVoted[key][msg.sender]) revert AlreadyVoted(msg.sender, key);

        hasVoted[key][msg.sender] = true;
        uint256 v = ++votes[key];
        emit Submitted(asset, msg.sender, roundId, key, v);

        // Only the vote that reaches quorum exactly triggers processing; later
        // identical votes are recorded but change nothing.
        if (v != quorum) return false;

        return _process(asset, cfg, roundId, answer, updatedAt);
    }

    /// @dev Malformed or replayed data REVERTS (nothing to review, just wrong input).
    ///      A plausible but large move does NOT revert: it trips the breaker.
    function _process(address asset, AssetConfig memory cfg, uint80 roundId, int256 answer, uint64 updatedAt)
        internal
        returns (bool)
    {
        // 1. Sanity
        if (answer <= 0) revert InvalidAnswer(answer);
        if (updatedAt > block.timestamp + MAX_FUTURE_DRIFT) revert FutureTimestamp(updatedAt, block.timestamp);

        // 2. Monotonic vs the newest round we know of (pending if tripped, else latest)
        PriceData memory last = tripped[asset] ? pending[asset] : latest[asset];
        if (last.updatedAt != 0 && (roundId <= last.roundId || updatedAt < last.updatedAt)) {
            revert NotNewer(roundId, updatedAt, last.roundId, last.updatedAt);
        }

        // 3. Scale Chainlink decimals -> 1e18
        // casting to uint256 is safe because answer > 0 was checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer) * 10 ** (18 - cfg.feedDecimals);
        PriceData memory incoming = PriceData({price: price, roundId: roundId, updatedAt: updatedAt});

        // 4. Already tripped: keep parking newer rounds for the reviewer.
        if (tripped[asset]) {
            pending[asset] = incoming;
            emit PendingUpdated(asset, roundId, price, updatedAt);
            return false;
        }

        // 5. Circuit breaker vs last trusted price
        uint256 trusted = latest[asset].price;
        if (trusted != 0) {
            uint256 diff = price > trusted ? price - trusted : trusted - price;
            if (diff * BPS > trusted * cfg.maxDeviationBps) {
                tripped[asset] = true;
                pending[asset] = incoming;
                emit CircuitBreakerTripped(asset, trusted, price, roundId);
                return false;
            }
        }

        // 6. Normal path
        latest[asset] = incoming;
        emit PriceUpdated(asset, roundId, price, updatedAt);
        return true;
    }

    // ---------------------------------------------------------------------
    // Read
    // ---------------------------------------------------------------------

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256) {
        AssetConfig memory cfg = assetConfig[asset];
        if (!cfg.enabled) revert AssetNotEnabled(asset);
        if (tripped[asset]) revert CircuitBreakerActive(asset);

        PriceData memory p = latest[asset];
        if (p.updatedAt == 0) revert NoPrice(asset);
        if (p.updatedAt < block.timestamp && block.timestamp - p.updatedAt > cfg.maxAge) {
            revert StalePrice(asset, p.updatedAt, cfg.maxAge);
        }
        return p.price;
    }
}
