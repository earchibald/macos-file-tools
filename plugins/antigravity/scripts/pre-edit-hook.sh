#!/bin/sh
# Antigravity runs this, from the plugin folder, just before it edits a file.
# It stores a disposable version of the file, then answers "allow", which
# hands the decision on to the user's normal permission settings: this hook
# never approves or blocks anything itself.
./bin/mft hook --by antigravity >/dev/null 2>&1
printf '%s\n' '{"decision":"allow"}'
exit 0
