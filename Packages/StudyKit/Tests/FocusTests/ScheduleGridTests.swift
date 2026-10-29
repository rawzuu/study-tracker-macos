import Focus
import Testing

@Suite struct ScheduleGridTests {
    @Test func windowsRoundTrip() {
        let windows = [TimeWindow(weekdays: [0, 1, 2, 3, 4], start: 8 * 60, end: 16 * 60), TimeWindow(weekdays: [5], start: 9 * 60, end: 12 * 60)]
        let grid = ScheduleGrid(windows: windows)
        #expect(grid[0, 16] && grid[0, 31] && !grid[0, 32] && !grid[0, 15])
        #expect(!grid[6, 20])
        #expect(grid.windows == windows)
    }

    @Test func overnightAndRounding() {
        // 22:15–1:10 v neděli → neděle 22:00–24:00 a pondělí 0:00–1:30.
        let grid = ScheduleGrid(windows: [TimeWindow(weekdays: [6], start: 22 * 60 + 15, end: 70)])
        #expect(grid.windows == [TimeWindow(weekdays: [0], start: 0, end: 90), TimeWindow(weekdays: [6], start: 22 * 60, end: 1440)])
    }

    @Test func paintingRectangle() {
        var grid = ScheduleGrid()
        grid.set(days: 1...3, slots: 18...19, to: true)
        #expect(grid.windows == [TimeWindow(weekdays: [1, 2, 3], start: 9 * 60, end: 10 * 60)])
        grid.set(days: 2...2, slots: 18...19, to: false)
        #expect(grid.windows == [TimeWindow(weekdays: [1, 3], start: 9 * 60, end: 10 * 60)])
        #expect(!grid.isEmpty)
        grid.set(days: 0...6, slots: 0...47, to: false)
        #expect(grid.isEmpty && grid.windows.isEmpty)
    }
}
