Restore NanoClaw on a new machine

This procedure restores the complete NanoClaw checkout and OneCLI state from a backup created by scripts/backup-nanoclaw.sh.

The OneCLI PostgreSQL backup is a logical pg_dump custom-format dump. Do not copy PostgreSQL's internal data directory during restore.

The backup contains credentials, encryption keys, chats, sessions, and configuration. Keep it only on encrypted storage.

1. Set the restore paths

Adjust these paths for the new machine:

BACKUP_DIR=/mnt/encrypted-backup/nanoclaw-YYYYMMDDTHHMMSSZ
NANO_ROOT=/var/home/vhforbes/sources/nanoclaw-v2
RESTORE_HOME=/var/home/vhforbes
ONECLI_ROOT="$RESTORE_HOME/.onecli"

Verify them:

printf 'BACKUP_DIR=%s\nNANO_ROOT=%s\nRESTORE_HOME=%s\nONECLI_ROOT=%s\n' \
  "$BACKUP_DIR" "$NANO_ROOT" "$RESTORE_HOME" "$ONECLI_ROOT"

2. Verify the backup

The backup must contain a completion marker and valid checksums:

test -f "$BACKUP_DIR/BACKUP_COMPLETE"
(cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS)
cat "$BACKUP_DIR/INFO.txt"

Every checksum must report OK.

Also verify that the PostgreSQL dump is present:

test -s "$BACKUP_DIR/onecli-postgres.dump"

Do not continue if checksum verification fails.

3. Restore the NanoClaw checkout

The target must not already exist.

test ! -e "$NANO_ROOT"

mkdir -p "$NANO_ROOT"

tar --xattrs --acls \
  -xzf "$BACKUP_DIR/nanoclaw.tar.gz" \
  -C "$NANO_ROOT"

cd "$NANO_ROOT"

This restores the repository, .git, .env, integrations, SQLite databases, sessions, groups, and uncommitted files.

Generated dependencies, build output, logs, sockets, and Docker images are intentionally excluded.

4. Install host prerequisites

Install Docker if necessary:

cd "$NANO_ROOT"
bash setup/install-docker.sh

Enable and start Docker:

sudo systemctl enable --now docker
docker info

A logout/login may be necessary if the installer added the user to the Docker group.

Install Node, pnpm, and the restored checkout's dependencies:

cd "$NANO_ROOT"
bash setup.sh

Do not run nanoclaw.sh. That is the new-install wizard and is not part of recovery.

5. Restore OneCLI configuration

The target OneCLI directory must not already exist:

test ! -e "$ONECLI_ROOT"

mkdir -p "$ONECLI_ROOT"

tar --xattrs --acls \
  -xzf "$BACKUP_DIR/onecli-config.tar.gz" \
  -C "$ONECLI_ROOT"

Define a helper for the restored Compose project:

onecli_compose() {
  docker compose \
    --project-directory "$ONECLI_ROOT" \
    -f "$ONECLI_ROOT/docker-compose.yml" \
    "$@"
}

Verify it:

onecli_compose config >/dev/null

6. Restore the exact container images

Read the immutable image references from the backup:

info_value() {
  sed -n "s/^$1=//p" "$BACKUP_DIR/INFO.txt"
}

ONECLI_IMAGE="$(info_value onecli_image)"
ONECLI_REPO_DIGEST="$(info_value onecli_repo_digest)"

POSTGRES_IMAGE="$(info_value postgres_image)"
POSTGRES_REPO_DIGEST="$(info_value postgres_repo_digest)"

POSTGRES_USER="$(info_value postgres_user)"
POSTGRES_DB="$(info_value postgres_db)"

printf 'OneCLI:    %s\nDigest:    %s\nPostgreSQL: %s\nDigest:    %s\n' \
  "$ONECLI_IMAGE" "$ONECLI_REPO_DIGEST" \
  "$POSTGRES_IMAGE" "$POSTGRES_REPO_DIGEST"

All values must be non-empty:

test -n "$ONECLI_IMAGE"
test -n "$ONECLI_REPO_DIGEST"
test -n "$POSTGRES_IMAGE"
test -n "$POSTGRES_REPO_DIGEST"
test -n "$POSTGRES_USER"
test -n "$POSTGRES_DB"

Pull the exact images used by the backup:

docker pull "$ONECLI_REPO_DIGEST"
docker tag "$ONECLI_REPO_DIGEST" "$ONECLI_IMAGE"

docker pull "$POSTGRES_REPO_DIGEST"
docker tag "$POSTGRES_REPO_DIGEST" "$POSTGRES_IMAGE"

Do not intentionally upgrade OneCLI or PostgreSQL during recovery.

7. Create stopped OneCLI containers with brand-new volumes

Record the Docker volumes that already exist:

EXISTING_VOLUMES="$(docker volume ls -q)"

Create the containers without starting them:

onecli_compose create postgres onecli

Get their IDs:

POSTGRES_ID="$(onecli_compose ps -q --all postgres)"
ONECLI_ID="$(onecli_compose ps -q --all onecli)"

test -n "$POSTGRES_ID"
test -n "$ONECLI_ID"

Determine the actual Docker volume names:

PG_VOLUME="$(
  docker inspect "$POSTGRES_ID" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Name}}{{end}}{{end}}'
)"

APP_VOLUME="$(
  docker inspect "$ONECLI_ID" \
    --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}'
)"

printf 'PostgreSQL volume: %s\nOneCLI app-data volume: %s\n' \
  "$PG_VOLUME" "$APP_VOLUME"

test -n "$PG_VOLUME"
test -n "$APP_VOLUME"

Verify that Compose did not reuse an existing named volume:

if printf '%s\n' "$EXISTING_VOLUMES" | grep -Fxq "$PG_VOLUME"; then
  echo "Refusing restore: PostgreSQL volume already existed: $PG_VOLUME" >&2
  false
fi

if printf '%s\n' "$EXISTING_VOLUMES" | grep -Fxq "$APP_VOLUME"; then
  echo "Refusing restore: OneCLI app-data volume already existed: $APP_VOLUME" >&2
  false
fi

Do not restore over an existing OneCLI installation.

8. Start PostgreSQL only

Start PostgreSQL:

onecli_compose start postgres

Wait until it is ready:

until onecli_compose exec -T postgres \
  pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1
do
  sleep 1
done

Confirm OneCLI itself is still stopped:

onecli_compose ps -a

9. Restore the OneCLI PostgreSQL database

Drop the newly initialized empty database:

onecli_compose exec -T postgres \
  dropdb -U "$POSTGRES_USER" "$POSTGRES_DB"

Recreate it with the correct owner:

onecli_compose exec -T postgres \
  createdb \
    -U "$POSTGRES_USER" \
    -O "$POSTGRES_USER" \
    "$POSTGRES_DB"

Restore the backup:

onecli_compose exec -T postgres \
  pg_restore \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    --no-owner \
    --no-privileges \
  < "$BACKUP_DIR/onecli-postgres.dump"

The command must finish without errors.

10. Restore OneCLI application data

The application-data archive contains OneCLI's runtime state and encryption key.

Restore it directly into the new app-data volume while the OneCLI application container is still stopped. The command clears any image-provided defaults first:

gzip -dc "$BACKUP_DIR/onecli-app-data.tar.gz" \
  | docker run --rm -i \
      -v "$APP_VOLUME:/data" \
      alpine \
      sh -c 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar -x -C /data'

Verify that the encryption key exists:

docker run --rm \
  -v "$APP_VOLUME:/data:ro" \
  alpine \
  test -f /data/secret-encryption-key

Do not start OneCLI if this check fails.

11. Verify the restored database before starting OneCLI

Define a helper:

onecli_count() {
  local table_name="$1"

  onecli_compose exec -T postgres \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At \
    -v ON_ERROR_STOP=1 \
    -c "
      SELECT CASE
        WHEN to_regclass('public.${table_name}') IS NULL THEN 'missing'
        ELSE (SELECT count(*)::text FROM public.${table_name})
      END;
    "
}

Compare the restored counts with the backup manifest:

for table in agents app_connections secrets vault_connections agent_secrets; do
  expected="$(info_value "onecli_${table}")"
  actual="$(onecli_count "$table")"

  printf '%-20s expected=%s actual=%s\n' "$table" "$expected" "$actual"

  test "$expected" = "$actual"
done

Every expected and actual value must match.

This is the important recovery check. Container health alone is not sufficient.

12. Start OneCLI

Start the OneCLI application:

onecli_compose up -d

Check health:

onecli_compose ps

Both services should report healthy.

Check the HTTP endpoint:

curl -fsS -o /dev/null http://172.17.0.1:10254/overview

Then open OneCLI and confirm the expected agents, app connections, and credentials are visible and usable.

Do not continue to NanoClaw until OneCLI is correct.

13. Restore NanoClaw host configuration

Restore only NanoClaw's shared host configuration.

A fresh systemd unit will be generated later for the new machine/path.

if [ -f "$BACKUP_DIR/nanoclaw-host-config.tar.gz" ]; then
  tar --xattrs --acls \
    -xzf "$BACKUP_DIR/nanoclaw-host-config.tar.gz" \
    -C "$RESTORE_HOME" \
    .config/nanoclaw
fi

Review the restored mount policy:

cat "$RESTORE_HOME/.config/nanoclaw/mount-allowlist.json"

Any host paths referenced there must exist on the new machine.

14. Rebuild NanoClaw

Build the agent image from the restored source:

cd "$NANO_ROOT"
./container/build.sh

This uses the restored .env, including options such as INSTALL_CJK_FONTS.

15. Generate and start the NanoClaw service

Generate only the service configuration for the new machine:

cd "$NANO_ROOT"
pnpm exec tsx setup/index.ts --step service

Determine the new systemd unit:

export NANOCLAW_PROJECT_ROOT="$NANO_ROOT"

source setup/lib/install-slug.sh

NANOCLAW_UNIT="$(systemd_unit)"

Verify it:

systemctl --user is-active "$NANOCLAW_UNIT"

The result must be:

active

16. Verify NanoClaw

Check the central SQLite database:

cd "$NANO_ROOT"

pnpm exec tsx scripts/q.ts \
  data/v2.db \
  "PRAGMA integrity_check"

The result must be:

ok

Check restored groups and sessions:

./bin/ncl groups list
./bin/ncl sessions list

Then verify the installation end to end:

Confirm the expected agent groups and channel wirings exist.

Send a message through Telegram and every other restored channel.

Confirm an agent remembers earlier context.

Run an action that uses a restored OneCLI credential.

Check scheduled tasks and their next-run times.

Review logs/nanoclaw.error.log for startup or delivery errors.

Do not run the old NanoClaw machine simultaneously during these tests.

Keep the encrypted backup unchanged until the recovery has been fully verified.

Recovery summary

The supported recovery flow is:

Verify checksums and BACKUP_COMPLETE.

Extract the complete NanoClaw checkout.

Install Docker, Node, pnpm, and dependencies.

Restore OneCLI configuration.

Pull the exact container image digests recorded by the backup.

Create fresh empty OneCLI volumes.

Start PostgreSQL only.

Restore onecli-postgres.dump with pg_restore.

Restore /app/data, including secret-encryption-key.

Compare restored OneCLI row counts with INFO.txt.

Start and verify OneCLI.

Restore NanoClaw host configuration.

Build the agent image.

Generate only the NanoClaw service setup.

Verify SQLite, groups, sessions, channels, and credentials.

No NanoClaw clone, temporary agents, fresh OneCLI setup, or fresh channel configuration is required.