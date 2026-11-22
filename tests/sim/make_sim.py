import re, sys
src, out, simdir = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding='utf-8').read()
s = s[:s.index('let app = NSApplication.shared')]
def rep(old, new, count=None):
    global s
    n = s.count(old)
    assert n >= 1 and (count is None or n == count), (old, n)
    s = s.replace(old, new)
# --- swap system layers for fakes (fakes live in fakes.swift) ---
rep('enum Power {', 'enum RealPower {', 1)
rep('enum Privileged {', 'enum RealPrivileged {', 1)
rep('final class Backlight {', 'final class RealBacklight {', 1)
rep('func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {', 'func realRun(_ path: String, _ args: [String]) -> (status: Int32, output: String) {', 1)
rep('IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep', 'fakeAssertionCreate(kIOPMAssertionTypePreventUserIdleSystemSleep', 1)
rep('IOPMAssertionRelease(idleAssertion)', 'fakeAssertionRelease(idleAssertion)')
rep('alert.runModal()', 'FakeUI.respond(alert)')
rep('NSApp.activate(', 'FakeUI.activate(')
rep('NSApp.terminate(nil)', 'FakeUI.terminate(nil)')
rep('UNUserNotificationCenter.current().add(request)', 'FakeUI.add(request)', 1)
rep('NSWorkspace.shared.recycle(', 'FakeUI.recycle(', 1)
rep('SMAppService.mainApp.status == .enabled ? .on : .off', '.off', 1)
rep('UserDefaults.standard', 'SimDefaults.d')
rep('"/tmp/nosleep_', '"%s/tmp_nosleep_' % simdir)
rep('FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)',
    'URL(fileURLWithPath: "%s", isDirectory: true)' % simdir, 1)
rep('let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)',
    'let statusItem: NSStatusItem = { let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); s.isVisible = false; return s }()', 1)
# open up private members so the test can drive them
s = re.sub(r'\bprivate (?!\()', '', s)
# safety: nothing in the sim build may reach the real system layer
for bad in ['IOPMAssertionCreateWithName(', 'NSWorkspace.shared.recycle', 'alert.runModal()', 'NSApp.terminate']:
    assert bad not in s.split('final class MenuBarController')[1].split('final class AppDelegate')[0], bad
open(out, 'w', encoding='utf-8').write(s)
print("ok", len(s.splitlines()), "lines")
