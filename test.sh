#!/bin/zsh
# Toggles the installed DeClutter twice: every on-screen window should vanish, then all come back with the same
# app in front. It really hides your apps for a few seconds. Run after ./build.sh install.
set -euo pipefail

# Prints the number of on-screen app windows (Dock apps only; system dialogs aren't DeClutter's to hide), then the
# frontmost app's name.
state() { swift - <<'EOF'
import AppKit
let apps = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
print(all.filter { $0[kCGWindowLayer as String] as? Int == 0 && apps.contains($0[kCGWindowOwnerPID as String] as? pid_t ?? 0) }.count,
      NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
EOF
}

read before app <<< "$(state)"
open -a DeClutter; sleep 2; read during _ <<< "$(state)"
open -a DeClutter; sleep 2; read after app_after <<< "$(state)"
echo "windows $before → $during → $after, front app $app → $app_after"
# If DeClutter itself was in front, Restore goes to the last ordinary app instead; never to loginwindow (focus on nothing).
[[ $before -gt 0 && $during -eq 0 && $after -eq $before && $app_after != loginwindow \
   && ( $app == DeClutter || $app == "$app_after" ) ]] && echo PASS || { echo FAIL; exit 1; }
