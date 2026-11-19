#!/usr/bin/env bash
# The macserve script shard `desktop-refs` (.macserve.json; template org-ios-sim-script-v1,
# PR check mac-evidence/org-ios-sim-script-v1/desktop-refs): Herdrup Desktop's references on
# the 13-inch and the 1180x820 pt iPad (Tools/ci/ui-shard.sh desktop-refs). The template runs
# a shard's file with no arguments, so this one runs macserve-ipad-script.sh, which holds the
# template contract (MACSERVE_SIMULATOR_ID, MACSERVE_APP_DIR, MACSERVE_OUTPUT), with the shard.
exec "$(dirname "$0")/macserve-ipad-script.sh" desktop-refs
