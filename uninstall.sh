#!/bin/zsh
# Stop mic-guard and remove everything install.sh added.
LABEL=local.mic-guard
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$LABEL.plist ~/.local/bin/mic-guard ~/.mic-guard-paused ~/Library/Logs/mic-guard.log
echo "Uninstalled. Your input device is left as it is now."
