#!/usr/bin/env bash
# The macserve script shard `settings-stack` (.macserve.json; template org-ios-sim-script-v1,
# PR check mac-evidence/org-ios-sim-script-v1/settings-stack). Despite its name it runs three
# things that need the job's own checkout: the built Herdr.app's version against project.yml,
# the iPad Settings resize/resume regression on an optimized Distribution build with the
# device-sized main stack (herdrup#416) and its attached-crash check, and the vendored
# SwiftTerm's UIKit API tests on iPad and iPhone (Tools/ci/ui-shard.sh settings-stack). The
# template runs a shard's file with no arguments, so this one runs macserve-script-shard.sh,
# which holds the template contract, with the shard.
exec "$(dirname "$0")/macserve-script-shard.sh" settings-stack
