// Pomocník zkoušky Strážce na CI (guard-e2e.sh): vypíše, jestli je aplikace schovaná, co je vpředu
// a kolik oken Strážce je na obrazovce (blokovací obrazovka + zakrytí dalších monitorů).
// Použití: guard-probe <bundle id aplikace> <pid Strážce>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    print("použití: guard-probe <bundle id> <pid Strážce>")
    exit(2)
}
let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first
let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
// Podle pid – jméno vlastníka okna je zobrazované jméno aplikace, ne název procesu.
let guardPid = Int(args[2]) ?? -1
let guardWindows = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == guardPid }
print("running=\(app != nil ? 1 : 0) hidden=\(app?.isHidden == true ? 1 : 0) front=\(front) guardWindows=\(guardWindows.count)")
