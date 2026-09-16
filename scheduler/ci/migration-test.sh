#!/usr/bin/env bash
# Verifies that the migrations embedded in IMAGE apply cleanly on top of a
# database dump without losing data, and that the service starts on the result.
#
# Env:
#   IMAGE       image under test (required)
#   DUMP_FILE   pg_dump of the production database, custom (-Fc) or plain SQL
#               format. Without it migrations are applied to an empty database,
#               which only proves that the SQL is valid.
#   PREV_IMAGE  image of the previous release. When set, it is started on the
#               migrated schema to check that rolling back the app without
#               restoring the database is possible (warning only).
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
DUMP_FILE="${DUMP_FILE:-}"
PREV_IMAGE="${PREV_IMAGE:-}"

RUN_ID="nettu-mt-$$"
NET="$RUN_ID"
PG="$RUN_ID-pg"
APP="$RUN_ID-app"
DB=nettuscheduler
DATABASE_URL="postgresql://postgres:postgres@$PG:5432/$DB"
APP_PORT="${APP_PORT:-15000}"
WORK="$(mktemp -d)"

log() { echo "==> $*"; }
warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$*"; else echo "WARNING: $*"; fi
}
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$*" >> "$GITHUB_STEP_SUMMARY" || true; }

cleanup() {
  docker rm -f "$APP" "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# No -i: psql_q runs inside `while read` loops and must not consume their stdin.
psql_q() { docker exec "$PG" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qAt "$@"; }
psql_stdin() { docker exec -i "$PG" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qAt; }

snapshot() {
  # "<table> <rows>" for every table except sqlx bookkeeping
  psql_q -c "select table_name from information_schema.tables
             where table_schema = 'public' and table_type = 'BASE TABLE'
               and table_name <> '_sqlx_migrations' order by 1" |
    while read -r t; do
      echo "$t $(psql_q -c "select count(*) from \"$t\"")"
    done
}

applied_migrations() {
  psql_q -c "select version from _sqlx_migrations where success order by version" 2>/dev/null || true
}

run_app() { # <image> <label>
  local image="$1" label="$2" key
  docker rm -f "$APP" >/dev/null 2>&1 || true
  # Reuse an existing account key so startup does not insert a new account.
  key="$(psql_q -c "select secret_api_key from accounts limit 1" 2>/dev/null || true)"
  docker run -d --name "$APP" --network "$NET" -p "127.0.0.1:$APP_PORT:5000" \
    -e DATABASE_URL="$DATABASE_URL" -e PORT=5000 ${key:+-e ACCOUNT_API_KEY="$key"} \
    --entrypoint ./nettu_scheduler "$image" >/dev/null

  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$APP_PORT/api/v1/" >/dev/null 2>&1; then break; fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$APP")" != "true" ]; then break; fi
    sleep 1
  done
  if ! curl -fsS "http://127.0.0.1:$APP_PORT/api/v1/" >/dev/null 2>&1; then
    docker logs "$APP" 2>&1 | tail -50
    echo "$label: service did not become healthy"
    return 1
  fi
  if [ -n "$key" ] && ! curl -fsS -H "x-api-key: $key" "http://127.0.0.1:$APP_PORT/api/v1/account" >/dev/null; then
    docker logs "$APP" 2>&1 | tail -50
    echo "$label: GET /api/v1/account with an existing account failed"
    return 1
  fi
  log "$label: healthy${key:+, existing account readable}"
}

docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB="$DB" postgres:13 >/dev/null
for _ in $(seq 1 60); do
  docker exec "$PG" pg_isready -U postgres -d "$DB" >/dev/null 2>&1 && break
  sleep 1
done
sleep 2

if [ -n "$DUMP_FILE" ]; then
  log "Restoring $DUMP_FILE"
  if [ "$(head -c 5 "$DUMP_FILE")" = "PGDMP" ]; then
    docker exec -i "$PG" pg_restore -U postgres -d "$DB" --no-owner --no-acl --exit-on-error < "$DUMP_FILE"
  else
    psql_stdin < "$DUMP_FILE" >/dev/null
  fi
  summary "- Dump: restored"
else
  warn "No dump provided: migrations are tested on an empty database only"
  summary "- Dump: **not provided**, empty database"
fi

applied_migrations > "$WORK/migrations.before"
snapshot > "$WORK/rows.before"
log "Before: $(wc -l < "$WORK/migrations.before" | tr -d ' ') migrations applied"
cat "$WORK/rows.before"

log "Running migrations from $IMAGE"
if ! docker run --rm --network "$NET" -e DATABASE_URL="$DATABASE_URL" --entrypoint ./migrate "$IMAGE"; then
  echo "Migration failed. VersionMissing(N) means the database already has migration N"
  echo "that this image does not contain (e.g. applied from another branch)."
  summary "- Migrations: **FAILED**"
  exit 1
fi
log "Running migrations again (must be a no-op)"
docker run --rm --network "$NET" -e DATABASE_URL="$DATABASE_URL" --entrypoint ./migrate "$IMAGE"

applied_migrations > "$WORK/migrations.after"
snapshot > "$WORK/rows.after"
new_migrations="$(comm -13 "$WORK/migrations.before" "$WORK/migrations.after" | tr '\n' ' ')"
log "New migrations: ${new_migrations:-none}"
summary "- New migrations: ${new_migrations:-none}"

failed=0
while read -r table before; do
  after="$(awk -v t="$table" '$1 == t { print $2 }' "$WORK/rows.after")"
  if [ -z "$after" ]; then
    echo "Table $table ($before rows) no longer exists"
    failed=1
  elif [ "$after" -lt "$before" ]; then
    echo "Table $table lost rows: $before -> $after"
    failed=1
  fi
done < "$WORK/rows.before"
if [ "$failed" -ne 0 ]; then
  summary "- Data check: **FAILED**"
  exit 1
fi
log "No table lost rows"
summary "- Data check: no table lost rows"

run_app "$IMAGE" "new image"
summary "- New image on migrated schema: healthy"

if [ -n "$PREV_IMAGE" ]; then
  if docker image inspect "$PREV_IMAGE" >/dev/null 2>&1 || docker pull -q "$PREV_IMAGE" >/dev/null 2>&1; then
    if run_app "$PREV_IMAGE" "previous image"; then
      summary "- Previous image ($PREV_IMAGE) on migrated schema: healthy, app-only rollback is possible"
    else
      warn "Previous image $PREV_IMAGE does not work on the migrated schema: rollback requires restoring the database backup"
      summary "- Previous image ($PREV_IMAGE) on migrated schema: **broken**, rollback needs DB restore"
    fi
  else
    warn "Previous image $PREV_IMAGE is not available, rollback compatibility not checked"
  fi
fi
