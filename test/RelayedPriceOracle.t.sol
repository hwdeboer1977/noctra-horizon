// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {RelayedPriceOracle} from "../src/RelayedPriceOracle.sol";

contract RelayedPriceOracleTest is Test {
    RelayedPriceOracle oracle;

    address owner = makeAddr("owner");
    address r1 = makeAddr("relayer1");
    address r2 = makeAddr("relayer2");
    address r3 = makeAddr("relayer3");
    address attacker = makeAddr("attacker");
    address weth = makeAddr("weth"); // just a key

    // Chainlink ETH/USD on Base has 8 decimals: $3,000 = 3000e8
    int256 constant P3000 = 3000e8;

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new RelayedPriceOracle(owner);
        vm.startPrank(owner);
        oracle.addRelayer(r1);
        oracle.addRelayer(r2);
        oracle.addRelayer(r3);
        oracle.setQuorum(2); // 2-of-3
        oracle.configureAsset(weth, 8, 3600, 2000); // 8 dec, 1h max age, 20% breaker
        vm.stopPrank();
    }

    /// Helper: relayer submits a round.
    function _submit(address relayer, uint80 roundId, int256 answer, uint256 updatedAt) internal returns (bool) {
        vm.prank(relayer);
        return oracle.submit(weth, roundId, answer, SafeCast.toUint64(updatedAt));
    }

    // --- quorum ------------------------------------------------------------

    function test_OneVoteIsNotEnough() public {
        assertFalse(_submit(r1, 1, P3000, block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.NoPrice.selector, weth));
        oracle.getPrice(weth);
    }

    function test_QuorumAcceptsAndScalesDecimals() public {
        _submit(r1, 1, P3000, block.timestamp);
        assertTrue(_submit(r2, 1, P3000, block.timestamp));
        assertEq(oracle.getPrice(weth), 3000e18); // 8 -> 18 decimals
    }

    function test_ThirdVoteAfterQuorumChangesNothing() public {
        _submit(r1, 1, P3000, block.timestamp);
        _submit(r2, 1, P3000, block.timestamp);
        assertFalse(_submit(r3, 1, P3000, block.timestamp));
        assertEq(oracle.getPrice(weth), 3000e18);
    }

    /// A single dishonest relayer cannot move the price: its data never matches.
    function test_MismatchedVotesDoNotCombine() public {
        _submit(r1, 1, P3000, block.timestamp);
        assertFalse(_submit(r2, 1, 1e8, block.timestamp)); // r2 lies: $1
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.NoPrice.selector, weth));
        oracle.getPrice(weth);

        assertTrue(_submit(r3, 1, P3000, block.timestamp)); // honest r3 completes quorum
        assertEq(oracle.getPrice(weth), 3000e18);
    }

    function test_RevertSameRelayerTwice() public {
        _submit(r1, 1, P3000, block.timestamp);
        vm.prank(r1);
        vm.expectRevert(); // AlreadyVoted
        oracle.submit(weth, 1, P3000, uint64(block.timestamp));
    }

    function test_RevertNotRelayer() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.NotRelayer.selector, attacker));
        oracle.submit(weth, 1, P3000, uint64(block.timestamp));
    }

    // --- safety checks on acceptance -------------------------------------------

    function test_RevertOlderRoundReplay() public {
        _submit(r1, 5, P3000, block.timestamp);
        _submit(r2, 5, P3000, block.timestamp);

        _submit(r1, 4, 3100e8, block.timestamp - 100);
        vm.prank(r2);
        vm.expectRevert(); // NotNewer
        oracle.submit(weth, 4, 3100e8, uint64(block.timestamp - 100));
    }

    function test_NewerRoundUpdates() public {
        _submit(r1, 1, P3000, block.timestamp);
        _submit(r2, 1, P3000, block.timestamp);
        vm.warp(block.timestamp + 60);
        _submit(r1, 2, 3050e8, block.timestamp);
        _submit(r2, 2, 3050e8, block.timestamp);
        assertEq(oracle.getPrice(weth), 3050e18);
    }

    // --- circuit breaker ---------------------------------------------------------

    /// Helper: trusted price $3,000 at round 1, then an agreed round 2 at `newAnswer`.
    function _tripTo(int256 newAnswer) internal returns (bool) {
        _submit(r1, 1, P3000, block.timestamp);
        _submit(r2, 1, P3000, block.timestamp);
        _submit(r1, 2, newAnswer, block.timestamp);
        return _submit(r2, 2, newAnswer, block.timestamp);
    }

    function test_SmallMoveDoesNotTrip() public {
        assertTrue(_tripTo(2500e8)); // -16.7% < 20%
        assertFalse(oracle.tripped(weth));
        assertEq(oracle.getPrice(weth), 2500e18);
    }

    /// Big move: does NOT revert, trips instead; getPrice fails closed immediately.
    function test_BigMoveTripsAndFailsClosed() public {
        assertFalse(_tripTo(2250e8)); // -25% > 20%

        assertTrue(oracle.tripped(weth));
        (uint256 trustedPrice,,) = oracle.latest(weth);
        assertEq(trustedPrice, 3000e18); // trusted price untouched
        (uint256 pendingPrice, uint80 pendingRound,) = oracle.pending(weth);
        assertEq(pendingPrice, 2250e18);
        assertEq(pendingRound, 2);

        // The old $3,000 is NOT usable any more, even though it is not stale.
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.CircuitBreakerActive.selector, weth));
        oracle.getPrice(weth);
    }

    function test_TripEmitsEvent() public {
        _submit(r1, 1, P3000, block.timestamp);
        _submit(r2, 1, P3000, block.timestamp);
        _submit(r1, 2, 2250e8, block.timestamp);
        vm.expectEmit(address(oracle));
        emit RelayedPriceOracle.CircuitBreakerTripped(weth, 3000e18, 2250e18, 2);
        _submit(r2, 2, 2250e8, block.timestamp);
    }

    /// While tripped, newer agreed rounds keep updating `pending` for the reviewer.
    function test_NewerRoundsUpdatePendingWhileTripped() public {
        _tripTo(2250e8);
        vm.warp(block.timestamp + 60);
        _submit(r1, 3, 2200e8, block.timestamp);
        assertFalse(_submit(r2, 3, 2200e8, block.timestamp));

        (uint256 pendingPrice, uint80 pendingRound,) = oracle.pending(weth);
        assertEq(pendingPrice, 2200e18);
        assertEq(pendingRound, 3);
        assertTrue(oracle.tripped(weth));
    }

    function test_RevertOlderRoundWhileTripped() public {
        _tripTo(2250e8);
        _submit(r1, 2, 2300e8, block.timestamp); // same round id as pending, different answer
        vm.prank(r2);
        vm.expectRevert(); // NotNewer vs pending
        oracle.submit(weth, 2, 2300e8, SafeCast.toUint64(block.timestamp));
    }

    /// Review outcome A: the crash was real -> accept pending as trusted.
    function test_AcceptPending() public {
        _tripTo(2250e8);
        vm.prank(owner);
        oracle.acceptPending(weth);

        assertFalse(oracle.tripped(weth));
        assertEq(oracle.getPrice(weth), 2250e18);
        (uint256 pendingPrice,,) = oracle.pending(weth);
        assertEq(pendingPrice, 0);

        // Normal updates resume, now checked against 2250.
        _submit(r1, 3, 2300e8, block.timestamp);
        assertTrue(_submit(r2, 3, 2300e8, block.timestamp));
        assertEq(oracle.getPrice(weth), 2300e18);
    }

    /// Review outcome B: the data was wrong -> discard pending, old price usable again.
    function test_ResetBreaker() public {
        _tripTo(2250e8);
        vm.prank(owner);
        oracle.resetBreaker(weth);

        assertFalse(oracle.tripped(weth));
        assertEq(oracle.getPrice(weth), 3000e18);
    }

    function test_RevertAcceptOrResetWhenNotTripped() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.NotTripped.selector, weth));
        oracle.acceptPending(weth);
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.NotTripped.selector, weth));
        oracle.resetBreaker(weth);
        vm.stopPrank();
    }

    function test_RevertAcceptPendingNotOwner() public {
        _tripTo(2250e8);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        oracle.acceptPending(weth);
    }

    /// Stablecoin config: a real depeg must reach the pool, so the breaker is loose.
    function test_UsdcDepegPassesLooseBreaker() public {
        address usdc = makeAddr("usdc");
        vm.prank(owner);
        oracle.configureAsset(usdc, 8, 90_000, 5000); // ~25h max age, 50% breaker

        vm.prank(r1);
        oracle.submit(usdc, 1, 1e8, SafeCast.toUint64(block.timestamp));
        vm.prank(r2);
        oracle.submit(usdc, 1, 1e8, SafeCast.toUint64(block.timestamp));

        vm.prank(r1);
        oracle.submit(usdc, 2, 0.9e8, SafeCast.toUint64(block.timestamp));
        vm.prank(r2);
        assertTrue(oracle.submit(usdc, 2, 0.9e8, SafeCast.toUint64(block.timestamp)));
        assertEq(oracle.getPrice(usdc), 0.9e18); // pool sees the depeg immediately
    }

    function test_RevertZeroOrNegativeAnswer() public {
        _submit(r1, 1, 0, block.timestamp);
        vm.prank(r2);
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.InvalidAnswer.selector, int256(0)));
        oracle.submit(weth, 1, 0, uint64(block.timestamp));
    }

    function test_RevertFutureTimestamp() public {
        uint256 ts = block.timestamp + 61;
        _submit(r1, 1, P3000, ts);
        vm.prank(r2);
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.FutureTimestamp.selector, ts, block.timestamp));
        oracle.submit(weth, 1, P3000, SafeCast.toUint64(ts));
    }

    // --- staleness uses Chainlink's updatedAt ------------------------------------

    /// Relaying an old Chainlink round NOW does not make it fresh.
    function test_StaleMeasuredFromChainlinkTime() public {
        uint256 oldTs = block.timestamp - 3601;
        _submit(r1, 1, P3000, oldTs);
        _submit(r2, 1, P3000, oldTs);
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.StalePrice.selector, weth, oldTs, 3600));
        oracle.getPrice(weth);
    }

    function test_PriceGoesStaleWhenRelayersStop() public {
        _submit(r1, 1, P3000, block.timestamp);
        _submit(r2, 1, P3000, block.timestamp);
        vm.warp(block.timestamp + 3601);
        vm.expectRevert();
        oracle.getPrice(weth);
    }

    // --- relayer set management ------------------------------------------------

    /// Removing a relayer bumps the epoch: its pending vote no longer counts.
    function test_RemovedRelayerVoteDoesNotCount() public {
        _submit(r1, 1, P3000, block.timestamp); // r1 votes
        vm.prank(owner);
        oracle.removeRelayer(r1);

        assertFalse(_submit(r2, 1, P3000, block.timestamp)); // would have been quorum with r1
        assertTrue(_submit(r3, 1, P3000, block.timestamp)); // r2 + r3 = new quorum
        assertEq(oracle.getPrice(weth), 3000e18);
    }

    function test_RevertRemoveBelowQuorum() public {
        vm.startPrank(owner);
        oracle.setQuorum(3);
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.InvalidQuorum.selector, 3, 2));
        oracle.removeRelayer(r1);
        vm.stopPrank();
    }

    function test_RevertQuorumAboveRelayerCount() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.InvalidQuorum.selector, 4, 3));
        oracle.setQuorum(4);
    }

    function test_RevertAdminNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        oracle.addRelayer(attacker);
    }

    function test_RevertUnconfiguredAsset() public {
        address usdc = makeAddr("usdc");
        vm.prank(r1);
        vm.expectRevert(abi.encodeWithSelector(RelayedPriceOracle.AssetNotEnabled.selector, usdc));
        oracle.submit(usdc, 1, 1e8, uint64(block.timestamp));
    }
}
