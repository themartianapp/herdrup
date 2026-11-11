#!/usr/bin/env bash
# Seconds-long checks of the CI tooling, run in CI's Linux job so a script error
# fails there instead of an hour into every macOS shard. PR #649's first head put a single
# quote inside Python passed to the interpreter as a shell-quoted string; it ended the shell
# string, the f-string broke, and every shard's class check failed.
#   - every Tools/ci shell script parses (bash -n);
#   - ui-shard.sh passes no Python inline with -c: its Python lives in Tools/ci/*.py;
#   - every Tools/ci/*.py and every quoted PY heredoc in ui-shard.sh compiles;
#   - every Tools/ci/test_*.py passes: the helpers' fixture tests and the CI scope
#     classifier's (ci_scope.py decides whether a PR skips the simulator matrix).
set -euo pipefail
cd "$(dirname "$0")"
status=0
for script in *.sh; do
  bash -n "$script" || status=1
done
if grep -nE 'python3? +-c' ui-shard.sh; then
  echo "::error file=Tools/ci/ui-shard.sh::Python passed with -c; move it into a Tools/ci/*.py file"
  status=1
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
awk -v out="$scratch/ui-shard-heredoc-" '
  /<<.PY.$/ { n++; on=1; next }
  on && /^PY$/ { on=0; next }
  on { print > (out n ".py") }
' ui-shard.sh
for source in *.py "$scratch"/*.py; do
  [ -e "$source" ] || continue
  PYTHONPYCACHEPREFIX="$scratch/cache" python3 -m py_compile "$source" || status=1
done
PYTHONPYCACHEPREFIX="$scratch/cache" python3 -m unittest discover -s . -p 'test_*.py' || status=1
exit "$status"
