#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -v
node --check web/app.js
node --test tests/test_web.cjs
python3 -m compileall -q backend scripts
sh -n db/00-roles.sh
sh -n scripts/upgrade-debate.sh
docker compose config --quiet
