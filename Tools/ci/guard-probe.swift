// Pomocník zkoušky Strážce na CI (guard-e2e.sh): vypíše, jestli je aplikace schovaná, co je vpředu
// a kolik oken Strážce je na obrazovce (blokovací obrazovka + zakrytí dalších monitorů).
// Použití: guard-probe <bundle id aplikace> <název procesu Strážce>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    print("použití: guard-probe <bundle id> <proces Strážce>")
    exit(2)
}
let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first
let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let guardWindows = windows.filter { $0[kCGWindowOwnerName as String] as? String == args[2] }
print("running=\(app != nil ? 1 : 0) hidden=\(app?.isHidden == true ? 1 : 0) front=\(front) guardWindows=\(guardWindows.count)")
