#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "======================================"
echo " MikroTik Graylog Monitor Installer"
echo "======================================"

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed."
    echo "Install Docker first, then run this installer again."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose plugin is not installed."
    exit 1
fi

# Create .env only on first install
if [ ! -f .env ]; then
    echo "Creating production .env..."

    GRAYLOG_PASSWORD_SECRET="$(openssl rand -hex 48)"
    OPENSEARCH_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9@#%+=' | head -c 24)"

    echo
    read -rsp "Create Graylog admin password: " GRAYLOG_ADMIN_PASSWORD
    echo

    if [ ${#GRAYLOG_ADMIN_PASSWORD} -lt 8 ]; then
        echo "ERROR: Graylog admin password must be at least 8 characters."
        exit 1
    fi

    GRAYLOG_ROOT_PASSWORD_SHA2="$(
        printf '%s' "$GRAYLOG_ADMIN_PASSWORD" | sha256sum | awk '{print $1}'
    )"

    cat > .env <<ENV
GRAYLOG_HTTP_PORT=9000
GRAYLOG_SYSLOG_PORT=514
GRAYLOG_PASSWORD_SECRET=${GRAYLOG_PASSWORD_SECRET}
GRAYLOG_ROOT_PASSWORD_SHA2=${GRAYLOG_ROOT_PASSWORD_SHA2}
OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_PASSWORD}
TZ=Asia/Phnom_Penh
ENV

    chmod 600 .env

    echo "Production secrets generated."
else
    echo ".env already exists. Keeping existing secrets."
    echo
    read -rsp "Enter existing Graylog admin password: " GRAYLOG_ADMIN_PASSWORD
    echo

    if [ -z "$GRAYLOG_ADMIN_PASSWORD" ]; then
        echo "ERROR: Graylog admin password is required."
        exit 1
    fi
fi

echo
echo "Validating Docker Compose..."
docker compose --env-file .env config >/dev/null

echo "Starting Graylog stack..."
docker compose --env-file .env up -d

echo
echo "Waiting for Graylog to become ready..."

MAX_WAIT=180
WAITED=0

while true; do
    STATUS="$(docker inspect \
      --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      graylog-graylog-1 2>/dev/null || true)"

    if [ "$STATUS" = "healthy" ]; then
        echo "Graylog container is healthy."
        break
    fi

    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        echo "ERROR: Graylog did not become healthy within ${MAX_WAIT} seconds."
        echo
        docker compose ps
        echo
        docker compose logs --tail=100 graylog
        exit 1
    fi

    printf "Graylog status: %s - waiting...\n" "${STATUS:-starting}"
    sleep 5
    WAITED=$((WAITED + 5))
done

echo
docker compose ps

echo
echo "Running Graylog configuration setup..."
GRAYLOG_PASSWORD="$GRAYLOG_ADMIN_PASSWORD" ./scripts/setup-graylog.sh
unset GRAYLOG_ADMIN_PASSWORD

echo
echo "======================================"
echo " Installation Complete"
echo "======================================"
echo
echo "Services:"
docker compose ps
echo
echo "Graylog Web:"
echo "  http://SERVER_IP:9000"
echo
echo "MikroTik Syslog:"
echo "  UDP port 514"
echo
echo "Next step:"
echo "  Configure the MikroTik router to send logs to this server."
