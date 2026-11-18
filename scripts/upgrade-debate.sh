#!/bin/sh
# Upgrade an existing install without removing volumes, scenarios, or transcripts.
set -eu
cd "$(dirname "$0")/.."
docker compose up -d db ollama
docker compose exec -T db sh -c 'until pg_isready -U postgres -d debate; do sleep 1; done'
docker compose exec -T db psql -U postgres -d debate -v ON_ERROR_STOP=1 < db/03-debate-upgrade.sql
# Explicitly download the new profile's model even if .env still names the old one.
docker compose exec -T ollama sh -c 'until ollama list >/dev/null 2>&1; do sleep 2; done; ollama pull qwen2.5:3b'
docker compose up --build -d backend web rest worker-rest
printf '%s\n' 'Upgrade complete. Refresh the browser and open a NEW room from the scenario library.' 'Existing rooms retain their original model/position snapshots; improved rebuttal prompts apply to all rooms.'
