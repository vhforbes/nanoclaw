#!/usr/bin/env bash
# Back up the local state unique to this NanoClaw installation.
# The destination must be encrypted: these files contain credentials and chats.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ONECLI_ROOT="${HOME}/.onecli"
DESTINATION="${1:-}"

if [ "$DESTINATION" = "--help" ]; then
  echo "Usage: $0 /path/to/encrypted-backup-directory"
  exit 0
fi

if [ -z "$DESTINATION" ]; then
  echo "Usage: $0 /path/to/encrypted-backup-directory" >&2
  exit 1
fi

for command_name in docker systemctl tar gzip sha256sum git node sync grep sed sort; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

[ -f "$ONECLI_ROOT/docker-compose.yml" ] || {
  echo "OneCLI configuration not found at $ONECLI_ROOT" >&2
  exit 1
}

mkdir -p "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd -P)"

case "$DESTINATION" in
  "$PROJECT_ROOT"|"$PROJECT_ROOT"/*)
    echo "Backup destination must be outside the NanoClaw repository" >&2
    exit 1
    ;;
esac

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FINAL_DIR="$DESTINATION/nanoclaw-$STAMP"
WORK_DIR="$DESTINATION/.nanoclaw-$STAMP.partial"

[ ! -e "$FINAL_DIR" ] && [ ! -e "$WORK_DIR" ] || {
  echo "A backup with this timestamp already exists" >&2
  exit 1
}

export NANOCLAW_PROJECT_ROOT="$PROJECT_ROOT"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/setup/lib/install-slug.sh"

NANOCLAW_UNIT="$(systemd_unit)"
INSTALL_SLUG="$(_nanoclaw_install_slug)"

# Refuse to stop a healthy host if the checkout cannot pass NanoClaw's
# upgrade tripwire on restart.
CURRENT_VERSION="$(node -e 'console.log(require(process.argv[1]).version)' "$PROJECT_ROOT/package.json")"
CURRENT_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"
CURRENT_TREE="$(git -C "$PROJECT_ROOT" rev-parse --verify 'HEAD^{tree}')"

if ! node -e '
  const fs = require("fs");
  const [markerPath, version, commit, tree] = process.argv.slice(1);
  try {
    const marker = JSON.parse(fs.readFileSync(markerPath, "utf8"));
    process.exit(
      marker.version === version &&
      marker.commit === commit &&
      marker.tree === tree ? 0 : 1
    );
  } catch {
    process.exit(1);
  }
' "$PROJECT_ROOT/data/upgrade-state.json" "$CURRENT_VERSION" "$CURRENT_COMMIT" "$CURRENT_TREE"; then
  echo "Backup aborted before stopping anything: NanoClaw's upgrade marker" >&2
  echo "does not match the current checkout, so the host would not restart." >&2
  echo "Complete the supported update/recovery first, then run the backup again." >&2
  echo "See: $PROJECT_ROOT/docs/upgrade-recovery.md" >&2
  exit 1
fi

compose() {
  docker compose \
    --project-directory "$ONECLI_ROOT" \
    -f "$ONECLI_ROOT/docker-compose.yml" \
    "$@"
}

container_env() {
  local container_id="$1"
  local key="$2"

  docker inspect "$container_id" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | sed -n "s/^${key}=//p" \
    | head -n 1
}

wait_for_postgres() {
  local attempts=60

  while (( attempts > 0 )); do
    if docker exec "$POSTGRES_ID" \
      pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempts=$((attempts - 1))
  done

  echo "PostgreSQL did not become ready" >&2
  return 1
}

table_count() {
  local table_name="$1"

  docker exec "$POSTGRES_ID" \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At \
    -v ON_ERROR_STOP=1 \
    -c "
      SELECT CASE
        WHEN to_regclass('public.${table_name}') IS NULL THEN 'missing'
        ELSE (SELECT count(*)::text FROM public.${table_name})
      END;
    "
}

NANOCLAW_WAS_RUNNING=false
ONECLI_WAS_RUNNING=false
POSTGRES_WAS_RUNNING=false
RESTORED=false
SESSION_CONTAINERS=()

systemctl --user is-active --quiet "$NANOCLAW_UNIT" && NANOCLAW_WAS_RUNNING=true

ONECLI_ID="$(compose ps -q --all onecli)"
POSTGRES_ID="$(compose ps -q --all postgres)"

[ -n "$ONECLI_ID" ] && [ -n "$POSTGRES_ID" ] || {
  echo "OneCLI containers have not been created" >&2
  exit 1
}

[ "$(docker inspect -f '{{.State.Running}}' "$ONECLI_ID")" = true ] && ONECLI_WAS_RUNNING=true
[ "$(docker inspect -f '{{.State.Running}}' "$POSTGRES_ID")" = true ] && POSTGRES_WAS_RUNNING=true

POSTGRES_USER="$(container_env "$POSTGRES_ID" POSTGRES_USER)"
POSTGRES_DB="$(container_env "$POSTGRES_ID" POSTGRES_DB)"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-$POSTGRES_USER}"

ONECLI_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$ONECLI_ID")"
POSTGRES_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$POSTGRES_ID")"
ONECLI_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$ONECLI_ID")"
POSTGRES_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$POSTGRES_ID")"
ONECLI_CONTAINER_ID_BEFORE="$ONECLI_ID"
POSTGRES_CONTAINER_ID_BEFORE="$POSTGRES_ID"
ONECLI_PORT_BINDINGS_BEFORE="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$ONECLI_ID")"
POSTGRES_PORT_BINDINGS_BEFORE="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$POSTGRES_ID")"

ONECLI_REPO_DIGEST="$(
  docker image inspect "$ONECLI_IMAGE_ID" \
    -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}'
)"
POSTGRES_REPO_DIGEST="$(
  docker image inspect "$POSTGRES_IMAGE_ID" \
    -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}'
)"

[ -n "$ONECLI_REPO_DIGEST" ] || {
  echo "Cannot determine an immutable digest for the OneCLI image" >&2
  exit 1
}

[ -n "$POSTGRES_REPO_DIGEST" ] || {
  echo "Cannot determine an immutable digest for the PostgreSQL image" >&2
  exit 1
}

restore_services() {
  local rc=0

  if $ONECLI_WAS_RUNNING; then
    # Start the existing containers without reconciling Compose configuration.
    # `up -d` may recreate OneCLI and silently change published ports.
    compose start postgres onecli >/dev/null || rc=1
  else
    compose stop onecli >/dev/null 2>&1 || true

    if $POSTGRES_WAS_RUNNING; then
      compose start postgres >/dev/null || rc=1
    else
      compose stop postgres >/dev/null 2>&1 || true
    fi
  fi

  for container_id in "${SESSION_CONTAINERS[@]}"; do
    if [ "$(docker inspect -f '{{.State.Paused}}' "$container_id" 2>/dev/null || true)" = true ]; then
      docker unpause "$container_id" >/dev/null || rc=1
    fi
  done

  if $NANOCLAW_WAS_RUNNING; then
    systemctl --user start "$NANOCLAW_UNIT" || rc=1
  fi

  return "$rc"
}

cleanup() {
  status=$?
  trap - EXIT INT TERM

  if ! $RESTORED; then
    restore_services || status=1
  fi

  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$WORK_DIR"

# Preserve every per-agent image tag. These images may contain approved
# packages that are not part of the base checkout.
mapfile -t PINNED_ROWS < <(node - "$PROJECT_ROOT" <<'NODE'
const Database = require(process.argv[2] + '/node_modules/better-sqlite3');
const db = new Database(process.argv[2] + '/data/v2.db', { readonly: true });
for (const row of db.prepare(`
  SELECT agent_group_id, image_tag FROM container_configs
  WHERE image_tag IS NOT NULL AND trim(image_tag) <> ''
  ORDER BY agent_group_id
`).all()) console.log(`${row.agent_group_id}|${row.image_tag}`);
NODE
)

PINNED_TAGS=()
: > "$WORK_DIR/nanoclaw-pinned-images.tsv"
for row in "${PINNED_ROWS[@]}"; do
  IFS='|' read -r agent_group_id image_tag <<< "$row"
  image_id="$(docker image inspect "$image_tag" --format '{{.Id}}' 2>/dev/null)" || {
    echo "Pinned agent image is unavailable: $image_tag" >&2
    exit 1
  }
  printf '%s|%s|%s\n' "$agent_group_id" "$image_tag" "$image_id" \
    >> "$WORK_DIR/nanoclaw-pinned-images.tsv"
  PINNED_TAGS+=("$image_tag")
done
NANOCLAW_PINNED_IMAGES="${#PINNED_ROWS[@]}"

if (( NANOCLAW_PINNED_IMAGES > 0 )); then
  echo "Saving $NANOCLAW_PINNED_IMAGES pinned NanoClaw agent image tag(s)..."
  mapfile -t UNIQUE_PINNED_TAGS < <(printf '%s\n' "${PINNED_TAGS[@]}" | sort -u)
  docker image save "${UNIQUE_PINNED_TAGS[@]}" \
    | gzip > "$WORK_DIR/nanoclaw-pinned-images.tar.gz"
  gzip -t "$WORK_DIR/nanoclaw-pinned-images.tar.gz"
  tar -tzf "$WORK_DIR/nanoclaw-pinned-images.tar.gz" >/dev/null
fi

echo "Stopping NanoClaw and OneCLI application for a consistent backup..."

$NANOCLAW_WAS_RUNNING && systemctl --user stop "$NANOCLAW_UNIT"

mapfile -t SESSION_CONTAINERS < <(
  docker ps -q --filter "label=nanoclaw-install=$INSTALL_SLUG"
)

if ((${#SESSION_CONTAINERS[@]})); then
  echo "Pausing ${#SESSION_CONTAINERS[@]} NanoClaw session container(s)..."
  docker pause "${SESSION_CONTAINERS[@]}" >/dev/null
fi

sync

# Read counts only after NanoClaw writers are stopped/paused so INFO.txt matches
# the SQLite state captured in nanoclaw.tar.gz.
NANOCLAW_AGENT_GROUPS="$(node - "$PROJECT_ROOT" <<'NODE'
const Database = require(process.argv[2] + '/node_modules/better-sqlite3');
const db = new Database(process.argv[2] + '/data/v2.db', { readonly: true });
process.stdout.write(String(db.prepare('SELECT count(*) AS n FROM agent_groups').get().n));
NODE
)"
NANOCLAW_SESSIONS="$(node - "$PROJECT_ROOT" <<'NODE'
const Database = require(process.argv[2] + '/node_modules/better-sqlite3');
const db = new Database(process.argv[2] + '/data/v2.db', { readonly: true });
process.stdout.write(String(db.prepare('SELECT count(*) AS n FROM sessions').get().n));
NODE
)"

if [ "$(docker inspect -f '{{.State.Running}}' "$ONECLI_ID")" = true ]; then
  compose stop onecli >/dev/null
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$POSTGRES_ID")" != true ]; then
  compose start postgres >/dev/null
fi

wait_for_postgres

echo "Recording OneCLI row counts..."
COUNT_AGENTS="$(table_count agents)"
COUNT_APP_CONNECTIONS="$(table_count app_connections)"
COUNT_SECRETS="$(table_count secrets)"
COUNT_VAULT_CONNECTIONS="$(table_count vault_connections)"
COUNT_AGENT_SECRETS="$(table_count agent_secrets)"

echo "Creating logical OneCLI PostgreSQL dump..."
docker exec "$POSTGRES_ID" \
  pg_dump \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    -Fc \
  > "$WORK_DIR/onecli-postgres.dump"

[ -s "$WORK_DIR/onecli-postgres.dump" ] || {
  echo "OneCLI PostgreSQL dump is empty" >&2
  exit 1
}

# Validate the custom-format dump using pg_restore from the same PostgreSQL image.
docker exec -i "$POSTGRES_ID" \
  pg_restore -l \
  < "$WORK_DIR/onecli-postgres.dump" \
  >/dev/null

echo "Copying NanoClaw state and installed integrations..."
tar --xattrs --acls -czf "$WORK_DIR/nanoclaw.tar.gz" \
  --exclude='./node_modules' \
  --exclude='./dist' \
  --exclude='./logs' \
  --exclude='./data/cli.sock' \
  --exclude='./data/ncl.sock' \
  --exclude='./nanoclaw.pid' \
  -C "$PROJECT_ROOT" .

echo "Copying OneCLI configuration and application data..."
tar --xattrs --acls -czf "$WORK_DIR/onecli-config.tar.gz" \
  -C "$ONECLI_ROOT" .

docker cp "$ONECLI_ID:/app/data/." - \
  | gzip > "$WORK_DIR/onecli-app-data.tar.gz"

gzip -t "$WORK_DIR/onecli-app-data.tar.gz"
tar -tzf "$WORK_DIR/onecli-app-data.tar.gz" >/dev/null

if ! tar -tzf "$WORK_DIR/onecli-app-data.tar.gz" \
  | grep -Eq '(^|^\./)secret-encryption-key$'; then
  echo "OneCLI app-data backup is missing secret-encryption-key" >&2
  exit 1
fi

HOST_FILES=()

[ -e "$HOME/.config/nanoclaw" ] && HOST_FILES+=(.config/nanoclaw)

[ -e "$HOME/.config/systemd/user/$NANOCLAW_UNIT.service" ] \
  && HOST_FILES+=(".config/systemd/user/$NANOCLAW_UNIT.service")

if ((${#HOST_FILES[@]})); then
  tar --xattrs --acls -czf "$WORK_DIR/nanoclaw-host-config.tar.gz" \
    -C "$HOME" "${HOST_FILES[@]}"
fi

{
  echo "backup_format=2"
  echo "created_utc=$STAMP"
  echo "nanoclaw_root=$PROJECT_ROOT"
  echo "backup_home=$HOME"
  echo "nanoclaw_commit=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "nanoclaw_unit=$NANOCLAW_UNIT"
  echo "nanoclaw_agent_groups=$NANOCLAW_AGENT_GROUPS"
  echo "nanoclaw_sessions=$NANOCLAW_SESSIONS"
  echo "nanoclaw_pinned_images=$NANOCLAW_PINNED_IMAGES"

  echo "onecli_image=$ONECLI_IMAGE"
  echo "onecli_image_id=$ONECLI_IMAGE_ID"
  echo "onecli_repo_digest=$ONECLI_REPO_DIGEST"

  echo "postgres_image=$POSTGRES_IMAGE"
  echo "postgres_image_id=$POSTGRES_IMAGE_ID"
  echo "postgres_repo_digest=$POSTGRES_REPO_DIGEST"
  echo "postgres_user=$POSTGRES_USER"
  echo "postgres_db=$POSTGRES_DB"

  echo "onecli_agents=$COUNT_AGENTS"
  echo "onecli_app_connections=$COUNT_APP_CONNECTIONS"
  echo "onecli_secrets=$COUNT_SECRETS"
  echo "onecli_vault_connections=$COUNT_VAULT_CONNECTIONS"
  echo "onecli_agent_secrets=$COUNT_AGENT_SECRETS"
} > "$WORK_DIR/INFO.txt"

echo "Restarting services..."
restore_services
RESTORED=true

# A backup must not reconcile or replace existing Compose containers.
[ "$(compose ps -q --all onecli)" = "$ONECLI_CONTAINER_ID_BEFORE" ] || {
  echo "OneCLI container identity changed during backup" >&2
  exit 1
}
[ "$(compose ps -q --all postgres)" = "$POSTGRES_CONTAINER_ID_BEFORE" ] || {
  echo "PostgreSQL container identity changed during backup" >&2
  exit 1
}
[ "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$ONECLI_ID")" = "$ONECLI_PORT_BINDINGS_BEFORE" ] || {
  echo "OneCLI published ports changed during backup" >&2
  exit 1
}
[ "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$POSTGRES_ID")" = "$POSTGRES_PORT_BINDINGS_BEFORE" ] || {
  echo "PostgreSQL published ports changed during backup" >&2
  exit 1
}

echo "Verifying backup..."

for archive in "$WORK_DIR"/*.tar.gz; do
  gzip -t "$archive"
  tar -tzf "$archive" >/dev/null
done

(
  cd "$WORK_DIR"
  sha256sum \
    ./*.tar.gz \
    ./onecli-postgres.dump \
    ./nanoclaw-pinned-images.tsv \
    ./INFO.txt \
    > SHA256SUMS

  sha256sum -c SHA256SUMS >/dev/null
)

echo "verified" > "$WORK_DIR/BACKUP_COMPLETE"
mv "$WORK_DIR" "$FINAL_DIR"

echo
echo "Backup complete: $FINAL_DIR"
echo "OneCLI counts:"
echo "  agents=$COUNT_AGENTS"
echo "  app_connections=$COUNT_APP_CONNECTIONS"
echo "  secrets=$COUNT_SECRETS"
echo "  vault_connections=$COUNT_VAULT_CONNECTIONS"
echo "  agent_secrets=$COUNT_AGENT_SECRETS"
echo
echo "Keep this directory only on encrypted storage."
echo "Restore guide: $PROJECT_ROOT/docs/backup-and-restore.md"
