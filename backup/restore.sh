#!/usr/bin/env bash
# Restore a NanoClaw format-2 disaster-recovery backup created by backup/backup.sh.
# Usage: bash restore.sh /path/to/nanoclaw-YYYYMMDDTHHMMSSZ [target-nanoclaw-root]

set -Eeuo pipefail
umask 077

BACKUP_DIR="${1:-}"
NANO_ROOT_OVERRIDE="${2:-}"
RESTORE_COMPLETE=false
COMPOSE_CREATED=false

usage() { echo "Usage: $0 /path/to/nanoclaw-backup [target-nanoclaw-root]"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$BACKUP_DIR" != "--help" && "$BACKUP_DIR" != "-h" ]] || { usage; exit 0; }
[[ -n "$BACKUP_DIR" ]] || { usage >&2; exit 1; }

for command_name in awk basename docker find gzip grep head mkdir node sed sha256sum sleep tar; do
  command -v "$command_name" >/dev/null 2>&1 || die "Missing required command: $command_name"
done

docker info >/dev/null 2>&1 || die "Docker is unavailable to this user"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd -P)"

for file in BACKUP_COMPLETE INFO.txt SHA256SUMS nanoclaw.tar.gz \
  onecli-config.tar.gz onecli-postgres.dump onecli-app-data.tar.gz \
  nanoclaw-pinned-images.tsv; do
  [[ -f "$BACKUP_DIR/$file" ]] || die "$file is missing"
done
[[ -s "$BACKUP_DIR/onecli-postgres.dump" ]] || die "onecli-postgres.dump is empty"

printf '%s\n' "Verifying backup checksums..."
(cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS)
for archive in "$BACKUP_DIR"/*.tar.gz; do gzip -t "$archive"; tar -tzf "$archive" >/dev/null; done

info_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$BACKUP_DIR/INFO.txt" | head -n 1
}
require_info() {
  local key="$1" value
  value="$(info_value "$key")"
  [[ -n "$value" ]] || die "$key missing from INFO.txt"
  printf '%s' "$value"
}

[[ "$(require_info backup_format)" == "2" ]] || die "Unsupported backup format"
OLD_HOME="$(require_info backup_home)"
OLD_NANO_ROOT="$(require_info nanoclaw_root)"
ONECLI_IMAGE="$(require_info onecli_image)"
ONECLI_REPO_DIGEST="$(require_info onecli_repo_digest)"
POSTGRES_IMAGE="$(require_info postgres_image)"
POSTGRES_REPO_DIGEST="$(require_info postgres_repo_digest)"
POSTGRES_USER="$(require_info postgres_user)"
POSTGRES_DB="$(require_info postgres_db)"
EXPECTED_PINNED="$(require_info nanoclaw_pinned_images)"
EXPECTED_GROUPS="$(require_info nanoclaw_agent_groups)"
EXPECTED_SESSIONS="$(require_info nanoclaw_sessions)"

for value_name in EXPECTED_PINNED EXPECTED_GROUPS EXPECTED_SESSIONS; do
  value="${!value_name}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$value_name is not a non-negative integer"
done

if [[ -n "$NANO_ROOT_OVERRIDE" ]]; then
  NANO_ROOT="${NANO_ROOT_OVERRIDE%/}"
elif [[ "$OLD_NANO_ROOT" == "$OLD_HOME/"* ]]; then
  NANO_ROOT="$HOME/${OLD_NANO_ROOT#"$OLD_HOME"/}"
else
  NANO_ROOT="$HOME/sources/$(basename "$OLD_NANO_ROOT")"
fi
[[ "$NANO_ROOT" == /* ]] || die "NanoClaw target must be an absolute path"
RESTORE_HOME="$HOME"
ONECLI_ROOT="$RESTORE_HOME/.onecli"

[[ ! -e "$NANO_ROOT" ]] || die "NanoClaw target already exists: $NANO_ROOT"
[[ ! -e "$ONECLI_ROOT" ]] || die "OneCLI target already exists: $ONECLI_ROOT"

tsv_rows="$(awk -F '|' 'NF == 3 && $1 != "" && $2 != "" && $3 != "" { n++ } END { print n+0 }' \
  "$BACKUP_DIR/nanoclaw-pinned-images.tsv")"
[[ "$tsv_rows" == "$EXPECTED_PINNED" ]] || die "Pinned image manifest count mismatch"
if (( EXPECTED_PINNED > 0 )); then
  [[ -f "$BACKUP_DIR/nanoclaw-pinned-images.tar.gz" ]] \
    || die "nanoclaw-pinned-images.tar.gz is missing"
fi

# Validate expected top-level content before creating target directories.
tar -tzf "$BACKUP_DIR/nanoclaw.tar.gz" | grep -Eq '(^|^\./)package.json$' \
  || die "nanoclaw.tar.gz does not contain package.json"
tar -tzf "$BACKUP_DIR/onecli-config.tar.gz" | grep -Eq '(^|^\./)docker-compose.yml$' \
  || die "onecli-config.tar.gz does not contain docker-compose.yml"
tar -tzf "$BACKUP_DIR/onecli-app-data.tar.gz" | grep -Eq '(^|^\./)secret-encryption-key$' \
  || die "onecli-app-data.tar.gz is missing secret-encryption-key"

cat <<PATHS

Restore paths:
  NanoClaw: $NANO_ROOT
  OneCLI:   $ONECLI_ROOT
  Home:     $RESTORE_HOME
PATHS

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if ! $RESTORE_COMPLETE; then
    if $COMPOSE_CREATED; then
      docker compose --project-directory "$ONECLI_ROOT" \
        -f "$ONECLI_ROOT/docker-compose.yml" stop >/dev/null 2>&1 || true
    fi
    echo "Restore failed. Newly created files/volumes were left stopped for inspection." >&2
    echo "Remove only the reported new targets after diagnosis before retrying." >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Pull immutable images before creating application state.
echo "Pulling exact OneCLI/PostgreSQL image digests..."
docker pull "$ONECLI_REPO_DIGEST" >/dev/null
docker tag "$ONECLI_REPO_DIGEST" "$ONECLI_IMAGE"
docker pull "$POSTGRES_REPO_DIGEST" >/dev/null
docker tag "$POSTGRES_REPO_DIGEST" "$POSTGRES_IMAGE"

if (( EXPECTED_PINNED > 0 )); then
  echo "Loading $EXPECTED_PINNED pinned NanoClaw agent image tag(s)..."
  gzip -dc "$BACKUP_DIR/nanoclaw-pinned-images.tar.gz" | docker image load >/dev/null
fi

while IFS='|' read -r agent_group_id image_tag expected_image_id; do
  [[ -n "$agent_group_id" && -n "$image_tag" && -n "$expected_image_id" ]] || continue
  actual_image_id="$(docker image inspect "$image_tag" --format '{{.Id}}' 2>/dev/null)" \
    || die "Pinned image missing after load: $image_tag"
  [[ "$actual_image_id" == "$expected_image_id" ]] \
    || die "Pinned image ID mismatch for $agent_group_id ($image_tag)"
done < "$BACKUP_DIR/nanoclaw-pinned-images.tsv"

echo "Extracting NanoClaw checkout..."
mkdir -p "$NANO_ROOT"
tar --xattrs --acls -xzf "$BACKUP_DIR/nanoclaw.tar.gz" -C "$NANO_ROOT"

echo "Bootstrapping Node, pnpm, and locked dependencies..."
(cd "$NANO_ROOT" && bash setup.sh)
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[[ ! -s "$NVM_DIR/nvm.sh" ]] || source "$NVM_DIR/nvm.sh"
hash -r 2>/dev/null || true
command -v node >/dev/null 2>&1 || die "Node is unavailable after setup.sh"
command -v pnpm >/dev/null 2>&1 || die "pnpm is unavailable after setup.sh"

echo "Restoring OneCLI configuration..."
mkdir -p "$ONECLI_ROOT"
tar --xattrs --acls -xzf "$BACKUP_DIR/onecli-config.tar.gz" -C "$ONECLI_ROOT"
onecli_compose() {
  docker compose --project-directory "$ONECLI_ROOT" -f "$ONECLI_ROOT/docker-compose.yml" "$@"
}
onecli_compose config >/dev/null

EXISTING_VOLUMES="$(docker volume ls -q)"
onecli_compose create postgres onecli >/dev/null
COMPOSE_CREATED=true
POSTGRES_ID="$(onecli_compose ps -q --all postgres)"
ONECLI_ID="$(onecli_compose ps -q --all onecli)"
[[ -n "$POSTGRES_ID" && -n "$ONECLI_ID" ]] || die "Could not create OneCLI containers"
PG_VOLUME="$(docker inspect "$POSTGRES_ID" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Name}}{{end}}{{end}}')"
APP_VOLUME="$(docker inspect "$ONECLI_ID" --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}')"
[[ -n "$PG_VOLUME" && -n "$APP_VOLUME" ]] || die "Could not determine OneCLI volumes"
for volume in "$PG_VOLUME" "$APP_VOLUME"; do
  if printf '%s\n' "$EXISTING_VOLUMES" | grep -Fxq "$volume"; then
    die "Refusing restore: volume already existed: $volume"
  fi
done

onecli_compose start postgres >/dev/null
attempts=90
until onecli_compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  attempts=$((attempts - 1))
  (( attempts > 0 )) || die "PostgreSQL did not become ready"
  sleep 1
done

echo "Restoring OneCLI PostgreSQL database..."
onecli_compose exec -T postgres dropdb -U "$POSTGRES_USER" "$POSTGRES_DB"
onecli_compose exec -T postgres createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$POSTGRES_DB"
onecli_compose exec -T postgres pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --no-owner --no-privileges < "$BACKUP_DIR/onecli-postgres.dump"

echo "Restoring OneCLI application data..."
gzip -dc "$BACKUP_DIR/onecli-app-data.tar.gz" | docker run --rm -i \
  --entrypoint sh -v "$APP_VOLUME:/data" "$POSTGRES_REPO_DIGEST" \
  -c 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar -x -C /data'
docker run --rm --entrypoint test -v "$APP_VOLUME:/data:ro" \
  "$POSTGRES_REPO_DIGEST" -f /data/secret-encryption-key \
  || die "Restored OneCLI app-data is missing secret-encryption-key"

onecli_count() {
  local table_name="$1"
  onecli_compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At \
    -v ON_ERROR_STOP=1 -c "SELECT CASE WHEN to_regclass('public.${table_name}') IS NULL
      THEN 'missing' ELSE (SELECT count(*)::text FROM public.${table_name}) END;"
}
for table in agents app_connections secrets vault_connections agent_secrets; do
  expected="$(require_info "onecli_${table}")"
  actual="$(onecli_count "$table")"
  printf '  %-20s expected=%s actual=%s\n' "$table" "$expected" "$actual"
  [[ "$expected" == "$actual" ]] || die "OneCLI table count mismatch for $table"
done

onecli_compose up -d >/dev/null
attempts=90
while (( attempts > 0 )); do
  health="$(docker inspect "$ONECLI_ID" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  [[ "$health" != "unhealthy" ]] || die "OneCLI became unhealthy"
  [[ "$health" != "healthy" && "$health" != "running" ]] || break
  attempts=$((attempts - 1)); sleep 1
done
(( attempts > 0 )) || die "OneCLI did not become healthy"

if [[ -f "$BACKUP_DIR/nanoclaw-host-config.tar.gz" ]] \
  && tar -tzf "$BACKUP_DIR/nanoclaw-host-config.tar.gz" | grep -Eq '(^|^\./)\.config/nanoclaw(/|$)'; then
  echo "Restoring NanoClaw host configuration..."
  tar --xattrs --acls -xzf "$BACKUP_DIR/nanoclaw-host-config.tar.gz" \
    -C "$RESTORE_HOME" .config/nanoclaw
fi

(cd "$NANO_ROOT" && ./container/build.sh)
NANO_DB_INTEGRITY="$(cd "$NANO_ROOT" && pnpm exec tsx scripts/q.ts data/v2.db 'PRAGMA integrity_check')"
[[ "$NANO_DB_INTEGRITY" == "ok" ]] || die "NanoClaw database integrity check failed"
ACTUAL_GROUPS="$(cd "$NANO_ROOT" && pnpm exec tsx scripts/q.ts data/v2.db 'SELECT count(*) FROM agent_groups')"
ACTUAL_SESSIONS="$(cd "$NANO_ROOT" && pnpm exec tsx scripts/q.ts data/v2.db 'SELECT count(*) FROM sessions')"
[[ "$EXPECTED_GROUPS" == "$ACTUAL_GROUPS" ]] || die "NanoClaw agent group count mismatch"
[[ "$EXPECTED_SESSIONS" == "$ACTUAL_SESSIONS" ]] || die "NanoClaw session count mismatch"

(cd "$NANO_ROOT" && pnpm exec tsx setup/index.ts --step service)
export NANOCLAW_PROJECT_ROOT="$NANO_ROOT"
source "$NANO_ROOT/setup/lib/install-slug.sh"
NANOCLAW_UNIT="$(systemd_unit)"
systemctl --user is-active --quiet "$NANOCLAW_UNIT" || die "NanoClaw service is not active"

RESTORE_COMPLETE=true
echo "Restore complete: $NANOCLAW_UNIT"
onecli_compose ps
(cd "$NANO_ROOT" && ./bin/ncl groups list && ./bin/ncl sessions list)
echo "Keep the old machine stopped while testing restored polling channels."
