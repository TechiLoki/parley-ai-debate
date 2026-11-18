#!/bin/sh
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v web_password="$WEB_DB_PASSWORD" -v worker_password="$WORKER_DB_PASSWORD" <<'SQL'
CREATE ROLE web_user NOLOGIN;
CREATE ROLE worker_user NOLOGIN;
SELECT format('CREATE ROLE web_auth NOINHERIT LOGIN PASSWORD %L', :'web_password') \gexec
SELECT format('CREATE ROLE worker_auth NOINHERIT LOGIN PASSWORD %L', :'worker_password') \gexec
GRANT web_user TO web_auth;
GRANT worker_user TO worker_auth;
SQL
