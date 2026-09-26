import Foundation

/// Converts a CGEvent timestamp to system uptime seconds. The timestamp is
/// documented as nanoseconds since boot but is mach ticks on some hardware; on
/// Apple Silicon those differ ~40x, so the unit is picked by which reading of the
/// value lands closer to "now". Only differences between two events are used.
enum EventUptime {
    static func seconds(
        fromEventTimestamp timestamp: UInt64,
        nowUptime: TimeInterval,
        nowMachTicks: UInt64,
        timebase: mach_timebase_info_data_t
    ) -> TimeInterval? {
        guard timestamp > 0, timebase.denom > 0 else { return nil }
        let asNanoseconds = Double(timestamp) / 1e9
        let ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let nowFromTicks = Double(nowMachTicks) * ticksToSeconds
        let distanceIfNanoseconds = abs(nowUptime - asNanoseconds)
        let distanceIfTicks = abs(nowFromTicks - Double(timestamp) * ticksToSeconds)
        guard distanceIfTicks < distanceIfNanoseconds else { return asNanoseconds }
        // Re-base onto the uptime clock so it compares with `nowUptime`.
        return nowUptime - (nowFromTicks - Double(timestamp) * ticksToSeconds)
    }

    /// Current clock readings for a live event.
    static func seconds(fromEventTimestamp timestamp: UInt64) -> TimeInterval? {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return seconds(
            fromEventTimestamp: timestamp,
            nowUptime: ProcessInfo.processInfo.systemUptime,
            nowMachTicks: mach_absolute_time(),
            timebase: timebase
        )
    }
}
