#!/bin/zsh
# Build mic-guard, install it to ~/.local/bin, and run it at login as a LaunchAgent.
set -euo pipefail
cd "${0:A:h}"

LABEL=local.mic-guard
PLIST=~/Library/LaunchAgents/$LABEL.plist
BIN=~/.local/bin/mic-guard

if ! command -v swiftc >/dev/null; then
    echo "swiftc not found. Install the Xcode Command Line Tools first:"
    echo "    xcode-select --install"
    exit 1
fi

echo "Building..."
mkdir -p build
swiftc -O main.swift -o build/mic-guard

mkdir -p ~/.local/bin ~/Library/LaunchAgents
rm -f "$BIN"
cp build/mic-guard "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/mic-guard.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/mic-guard.log</string>
</dict>
</plist>
EOF

launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
# bootout returns before the old process has gone; wait so bootstrap doesn't fail
for i in {1..20}; do
    launchctl print gui/$(id -u)/$LABEL >/dev/null 2>&1 || break
    sleep 0.25
done
launchctl bootstrap gui/$(id -u) "$PLIST"

echo "Installed. mic-guard is running and will start at login."
echo "Log: ~/Library/Logs/mic-guard.log"
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo
    echo "Note: ~/.local/bin is not on your PATH, so the mic-guard command won't be found."
    echo "Add this line to ~/.zshrc, then open a new terminal:"
    echo '    export PATH="$HOME/.local/bin:$PATH"'
fi
