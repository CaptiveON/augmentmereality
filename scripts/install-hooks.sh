#!/bin/sh
# Round 15 (counsel F-SEAMS-14-4): core.hooksPath is machine-local git config
# and does not survive a clone — run this once per checkout so the drift locks
# (emoji + reaction-key vs firestore.rules) gate every commit.
set -e
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
echo "hooks installed: $(git config core.hooksPath)"
