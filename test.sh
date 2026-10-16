#!/bin/zsh
# Toggles the installed DeClutter twice: every on-screen window should vanish, then all come back with the same
# app in front. Then declutters again and quits DeClutter, which must bring every window back too, minimized ones
# included (as at logout or a reinstall). It really hides your apps for a few seconds. Run after ./build.sh install.
set -euo pipefail

# Prints the number of on-screen app windows (Dock apps only; system dialogs aren't DeClutter's to hide), the number
# of minimized ones (-1 when this terminal has no Accessibility permission to see them), then the frontmost app.
state() { swift - <<'EOF'
import AppKit
let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
let apps = Set(regular.map(\.processIdentifier))
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
var minimized = AXIsProcessTrusted() ? 0 : -1
for app in regular where minimized >= 0 {
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &windows)
    for window in windows as? [AXUIElement] ?? [] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
        if value as? Bool == true { minimized += 1 }
    }
}
print(all.filter { $0[kCGWindowLayer as String] as? Int == 0 && apps.contains($0[kCGWindowOwnerPID as String] as? pid_t ?? 0) }.count,
      minimized, NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
EOF
}

read before min_before app <<< "$(state)"
open -a DeClutter; sleep 2; read during _ _ <<< "$(state)"
open -a DeClutter; sleep 2; read after _ app_after <<< "$(state)"
echo "windows $before → $during → $after, front app $app → $app_after"
# If DeClutter itself was in front, Restore goes to the last ordinary app instead; never to loginwindow (focus on nothing).
[[ $before -gt 0 && $during -eq 0 && $after -eq $before && $app_after != loginwindow \
   && ( $app == DeClutter || $app == "$app_after" ) ]] || { echo FAIL; exit 1; }

open -a DeClutter; sleep 2; read cleared min_cleared _ <<< "$(state)"
pgrep -x DeClutter >/dev/null && pkill -x DeClutter
for _ in {1..50}; do pgrep -x DeClutter >/dev/null || break; sleep 0.1; done
sleep 2; read quit min_quit _ <<< "$(state)"
open -a DeClutter
echo "quit while clear: windows $cleared → $quit, in the Dock $min_before → $min_cleared → $min_quit"
[[ $cleared -eq 0 && $quit -eq $before ]] || { echo FAIL; exit 1; }
# With Animate on, windows must really have gone to the Dock and come back out, or the quit step proved nothing.
if [[ $(defaults read io.github.danpune.declutter animate 2>/dev/null || echo 1) == 0 ]]; then
  echo "PASS (Animate is off: hiding only)"
elif [[ $min_before -lt 0 ]]; then
  echo "PASS (minimized windows not checked: give this terminal Accessibility permission to check them)"
elif [[ $min_cleared -gt $min_before && $min_quit -eq $min_before ]]; then
  echo PASS
else
  echo "FAIL: Animate is on but no windows went to the Dock and back. Has DeClutter lost its Accessibility permission?"; exit 1
fi
