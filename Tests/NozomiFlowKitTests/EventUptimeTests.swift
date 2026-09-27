import XCTest
@testable import NozomiFlowKit

/// Key hold length now comes from the key events' own timestamps, because a
/// cold mic can block the main thread for ~2 s at key-down and a clock read when
/// the key-up is finally handled would count that wait as holding the key.
/// CGEvent timestamps are documented as nanoseconds but are mach ticks on some
/// hardware; the two differ ~40x on Apple Silicon, so the unit is detected.
final class EventUptimeTests: XCTestCase {

    private let appleSilicon = mach_timebase_info_data_t(numer: 125, denom: 3)

    func testNanosecondTimestampsConvertDirectly() {
        let uptime = EventUptime.seconds(
            fromEventTimestamp: 7_947_000_000_000, nowUptime: 7_947.2,
            nowMachTicks: 190_728_000_000, timebase: appleSilicon)
        XCTAssertEqual(try XCTUnwrap(uptime), 7_947.0, accuracy: 0.001)
    }

    func testMachTickTimestampsAreConvertedWithTheTimebase() {
        // 190_728_000_000 ticks * 125/3 = 7_947_000_000_000 ns
        let uptime = EventUptime.seconds(
            fromEventTimestamp: 190_728_000_000, nowUptime: 7_947.2,
            nowMachTicks: 190_732_800_000, timebase: appleSilicon)
        XCTAssertEqual(try XCTUnwrap(uptime), 7_947.0, accuracy: 0.001)
    }

    func testZeroTimestampMeansUnknown() {
        XCTAssertNil(EventUptime.seconds(fromEventTimestamp: 0, nowUptime: 10, nowMachTicks: 240, timebase: appleSilicon))
    }
}
