#!/bin/bash
# Activate an element of the running LocalMusic window through Accessibility, without moving the user's mouse:
# finds the first element whose name/value/description equals $1, walks up to the nearest row (selects it) or
# pressable element (AXPress). Never synthesizes a mouse click, so nothing can land in another app.
# Requires the terminal's Accessibility grant.
# Usage: Scripts/ax-click.sh 专辑
set -euo pipefail
osascript - "$1" <<'EOF'
on run argv
  set needle to item 1 of argv
  tell application "System Events"
    set p to first process whose unix id is ((do shell script "pgrep -n LocalMusic") as integer)
    set elements to entire contents of window 1 of p
    repeat with e in elements
      set hit to false
      try
        set hit to (name of e is needle) or (value of e is needle) or (description of e is needle)
      end try
      if hit then
        set target to contents of e
        repeat 5 times
          if role of target is "AXRow" then
            set value of attribute "AXSelected" of target to true
            return "selected row " & needle
          end if
          if (name of actions of target) contains "AXPress" then
            perform action "AXPress" of target
            return "pressed " & needle
          end if
          set target to value of attribute "AXParent" of target
        end repeat
        error "no accessible action for " & needle
      end if
    end repeat
  end tell
  error "element not found: " & needle
end run
EOF
