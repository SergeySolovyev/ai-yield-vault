// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RateMath} from "../../src/libraries/RateMath.sol";

/// @dev Wrapper to make internal library calls external (needed for vm.expectRevert)
contract RateMathHarness {
    function emaSmooth(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return RateMath.emaSmooth(a, b, c);
    }
}

contract RateMathTest is Test {
    RateMathHarness harness;

    function setUp() public {
        harness = new RateMathHarness();
    }
    // ========== normalizeAaveRate ==========

    function test_normalizeAaveRate_5percent() public pure {
        // Aave 5% APY in RAY = 0.05 * 1e27 = 5e25
        uint256 liquidityRateRay = 5e25;
        uint256 normalized = RateMath.normalizeAaveRate(liquidityRateRay);
        // Expected: 5e25 / 1e9 = 5e16 (0.05 * 1e18)
        assertEq(normalized, 5e16, "5% APY should normalize to 5e16");
    }

    function test_normalizeAaveRate_zero() public pure {
        assertEq(RateMath.normalizeAaveRate(0), 0, "Zero rate should stay zero");
    }

    function test_normalizeAaveRate_highRate() public pure {
        // 20% APY in RAY = 2e26
        uint256 liquidityRateRay = 2e26;
        uint256 normalized = RateMath.normalizeAaveRate(liquidityRateRay);
        assertEq(normalized, 2e17, "20% APY should normalize to 2e17");
    }

    function testFuzz_normalizeAaveRate(uint256 rayRate) public pure {
        // Bound to realistic range (0-100% APY in RAY)
        rayRate = bound(rayRate, 0, 1e27);
        uint256 normalized = RateMath.normalizeAaveRate(rayRate);
        // Result should always be <= 1e18 (100%)
        assertLe(normalized, 1e18, "Normalized rate should not exceed 100%");
    }

    // ========== normalizeCompoundRate ==========

    function test_normalizeCompoundRate_5percent() public pure {
        // Compound 5% APY: perSecondRate = 0.05 / SECONDS_PER_YEAR
        // SECONDS_PER_YEAR = 365.25 * 86400 = 31_557_600
        // perSecondRate = 5e16 / 31_557_600 ≈ 1_584_404_393
        uint256 perSecondRate = uint256(5e16) / 31_557_600;
        uint256 normalized = RateMath.normalizeCompoundRate(perSecondRate);
        // Due to integer division, there will be slight rounding
        // The result should be close to 5e16 (within 1e14 tolerance)
        assertApproxEqAbs(normalized, 5e16, 1e14, "~5% APY from Compound");
    }

    function test_normalizeCompoundRate_zero() public pure {
        assertEq(RateMath.normalizeCompoundRate(0), 0, "Zero rate should stay zero");
    }

    function testFuzz_normalizeCompoundRate(uint256 perSecRate) public pure {
        // Bound to realistic per-second rates (0 to ~100% APY)
        // 100% APY ≈ 1e18 / 31_557_600 ≈ 3.17e10 per second
        perSecRate = bound(perSecRate, 0, 4e10);
        uint256 normalized = RateMath.normalizeCompoundRate(perSecRate);
        // Should not overflow and should be <= ~130% APY
        assertLe(normalized, 2e18, "Annualized rate should be reasonable");
    }

    // ========== emaSmooth ==========

    function test_emaSmooth_firstObservation() public pure {
        // When previousSmoothed is 0, return currentRate directly
        uint256 result = RateMath.emaSmooth(5e16, 0, 3000);
        assertEq(result, 5e16, "First observation should return current rate");
    }

    function test_emaSmooth_fullWeightOnNew() public pure {
        // alpha = 10000 (100%) → result = current
        uint256 result = RateMath.emaSmooth(5e16, 3e16, 10000);
        assertEq(result, 5e16, "100% alpha should return current rate");
    }

    function test_emaSmooth_fullWeightOnOld() public pure {
        // alpha = 0 (0%) → result = previous
        uint256 result = RateMath.emaSmooth(5e16, 3e16, 0);
        assertEq(result, 3e16, "0% alpha should return previous rate");
    }

    function test_emaSmooth_standard() public pure {
        // alpha = 3000 (30%), current = 10%, previous = 5%
        // Expected: 0.3 * 10% + 0.7 * 5% = 3% + 3.5% = 6.5%
        uint256 result = RateMath.emaSmooth(10e16, 5e16, 3000);
        assertEq(result, 65e15, "30/70 blend of 10% and 5% should be 6.5%");
    }

    function test_emaSmooth_revertsOnInvalidAlpha() public {
        vm.expectRevert("RateMath: alpha > 100%");
        harness.emaSmooth(5e16, 3e16, 10001);
    }

    function testFuzz_emaSmooth_boundedOutput(
        uint256 current,
        uint256 previous,
        uint256 alpha
    ) public pure {
        current = bound(current, 0, 1e18);
        previous = bound(previous, 1, 1e18); // >0 to test blending
        alpha = bound(alpha, 0, 10000);

        uint256 result = RateMath.emaSmooth(current, previous, alpha);

        // Result should be between min(current, previous) and max(current, previous)
        uint256 lower = current < previous ? current : previous;
        uint256 upper = current > previous ? current : previous;
        assertGe(result, lower, "EMA should not go below minimum input");
        assertLe(result, upper, "EMA should not exceed maximum input");
    }

    // ========== rateToBps ==========

    function test_rateToBps_5percent() public pure {
        assertEq(RateMath.rateToBps(5e16), 500, "5% should be 500 bps");
    }

    function test_rateToBps_zero() public pure {
        assertEq(RateMath.rateToBps(0), 0, "0% should be 0 bps");
    }

    function test_rateToBps_100percent() public pure {
        assertEq(RateMath.rateToBps(1e18), 10000, "100% should be 10000 bps");
    }

    // ========== absDiff ==========

    function test_absDiff_aGreaterThanB() public pure {
        assertEq(RateMath.absDiff(10, 3), 7);
    }

    function test_absDiff_bGreaterThanA() public pure {
        assertEq(RateMath.absDiff(3, 10), 7);
    }

    function test_absDiff_equal() public pure {
        assertEq(RateMath.absDiff(5, 5), 0);
    }

    function testFuzz_absDiff_commutative(uint256 a, uint256 b) public pure {
        assertEq(RateMath.absDiff(a, b), RateMath.absDiff(b, a), "absDiff should be commutative");
    }
}
