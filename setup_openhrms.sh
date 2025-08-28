#!/usr/bin/env bash
set -euo pipefail

### ========= USER VARS =========
DB_NAME="openhrms11"
MASTER_PASSWORD="${ODOO_MASTER_PASSWORD:-gzi8-ugye-ivxp}"
WITH_DEMO="0"                # 0 = no demo data, 1 = include demo data
LANGUAGE="en_US"
HOST_HTTP_PORT="8069"        # final URL -> http://localhost:8069/web
ODOO_IMAGE="odoo:11.0"       # official Odoo 11 image
PG_IMAGE="postgres:10"
NET="odoo-net"
ROOT="/opt/openhrms"         # host path to store configs/addons/data
### ===============================================

echo "==> Preparing host folders at ${ROOT}"
sudo mkdir -p "${ROOT}"/{config,logs,addons,pgdata}
sudo chown -R "$USER":"$USER" "${ROOT}" || true
LOGFILE="${ROOT}/logs/openhrms.log"
CONF="${ROOT}/config/odoo.conf"

# Install Docker (and compose plugin) if absent
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker"
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release; echo "$UBUNTU_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Ensure Docker daemon is running (GitHub runners already do)
sudo systemctl start docker || true

echo "==> Creating Docker network: ${NET}"
docker network inspect "${NET}" >/dev/null 2>&1 || docker network create "${NET}"

echo "==> Pulling images: ${PG_IMAGE} and ${ODOO_IMAGE}"
docker pull "${PG_IMAGE}"
docker pull "${ODOO_IMAGE}"

echo "==> Starting PostgreSQL 10 container"
docker rm -f odoo-db >/dev/null 2>&1 || true
docker run -d --name odoo-db --network "${NET}" \
  -e POSTGRES_USER=odoo \
  -e POSTGRES_PASSWORD=odoo \
  -e POSTGRES_DB=postgres \
  -v "${ROOT}/pgdata:/var/lib/postgresql/data" \
  "${PG_IMAGE}"

# Wait for PG to be ready
echo "==> Waiting for PostgreSQL to accept connections..."
until docker exec odoo-db pg_isready -U odoo -h localhost >/dev/null 2>&1; do
  sleep 1
done

echo "==> Cloning OpenHRMS 11 addons"
rm -rf "${ROOT}/addons/openhrms"
git clone --depth 1 --branch 11.0 https://github.com/CybroOdoo/OpenHRMS.git "${ROOT}/addons/openhrms"

echo "==> Writing Odoo configuration to ${CONF}"
cat > "${CONF}" <<EOF
[options]
; Master password for database manager
admin_passwd = ${MASTER_PASSWORD}

; Postgres
db_host = odoo-db
db_port = 5432
db_user = odoo
db_password = odoo

; Addons (core addons are in the image; mount extra addons here)
addons_path = /mnt/extra-addons/openhrms

; Logging
logfile = /var/log/openhrms/openhrms.log

; HTTP
http_port = 8069
proxy_mode = False
EOF

# Permissions for mounted files
sudo chown -R 1000:1000 "${ROOT}"  # 'odoo' user in the image

# Ensure pandas is available in the container (needed by OpenHRMS dashboard etc.)
# We do this in every headless run so it's present even on fresh runners. 
PIP_BOOT="python3 -c 'import sys; print(sys.version)' >/dev/null 2>&1 || true; \
          (pip3 install --no-cache-dir \"pandas==0.24.2\" || pip install --no-cache-dir \"pandas==0.24.2\")"

# One-shot: create DB headlessly (no web page) 
echo "==> Creating database '${DB_NAME}' (headless)"
docker rm -f odoo-init >/dev/null 2>&1 || true
docker run --rm --name odoo-init --network "${NET}" \
  -v "${ROOT}/config:/etc/odoo" \
  -v "${ROOT}/logs:/var/log/openhrms" \
  -v "${ROOT}/addons:/mnt/extra-addons" \
  "${ODOO_IMAGE}" \
  bash -lc "${PIP_BOOT} && \
            odoo -c /etc/odoo/odoo.conf \
                 -d '${DB_NAME}' \
                 -i base \
                 $( [ '${WITH_DEMO}' = '0' ] && echo --without-demo=all ) \
                 --load-language='${LANGUAGE}' \
                 --stop-after-init"

# Build a comma-separated list of ALL OpenHRMS modules (directories with manifest files)
echo '==> Resolving all OpenHRMS module names'
ALL_MODS=$(docker run --rm --network "${NET}" \
  -v "${ROOT}/addons:/mnt/extra-addons" \
  "${ODOO_IMAGE}" \
  bash -lc "python3 - <<'PY'
import os, sys
root = '/mnt/extra-addons/openhrms'
mods = []
for d in sorted(os.listdir(root)):
    p = os.path.join(root, d)
    if not os.path.isdir(p): 
        continue
    if os.path.isfile(os.path.join(p, '__manifest__.py')) or os.path.isfile(os.path.join(p, '__openerp__.py')):
        mods.append(d)
print(','.join(mods))
PY")

if [ -z "${ALL_MODS}" ]; then
  echo "!! Could not find module list under ${ROOT}/addons/openhrms"
  exit 1
fi
echo "    Modules: ${ALL_MODS}"

# Install *all* OpenHRMS modules headlessly
echo "==> Installing ALL OpenHRMS modules into '${DB_NAME}'"
docker run --rm --network "${NET}" \
  -v "${ROOT}/config:/etc/odoo" \
  -v "${ROOT}/logs:/var/log/openhrms" \
  -v "${ROOT}/addons:/mnt/extra-addons" \
  "${ODOO_IMAGE}" \
  bash -lc "${PIP_BOOT} && \
            odoo -c /etc/odoo/odoo.conf \
                 -d '${DB_NAME}' \
                 -i ${ALL_MODS} \
                 $( [ '${WITH_DEMO}' = '0' ] && echo --without-demo=all ) \
                 --stop-after-init"

# Run Odoo for real
echo "==> Starting Odoo 11 server (exposes http://localhost:${HOST_HTTP_PORT}/web)"
docker rm -f odoo >/dev/null 2>&1 || true
docker run -d --name odoo --network "${NET}" \
  -p "${HOST_HTTP_PORT}:8069" \
  -v "${ROOT}/config:/etc/odoo" \
  -v "${ROOT}/logs:/var/log/openhrms" \
  -v "${ROOT}/addons:/mnt/extra-addons" \
  "${ODOO_IMAGE}"

# Health check
echo "==> Waiting for Odoo to listen on localhost:${HOST_HTTP_PORT}"
for i in {1..90}; do
  if curl -sSf "http://localhost:${HOST_HTTP_PORT}/web?db=${DB_NAME}" >/dev/null; then
    OK=1; break
  fi
  sleep 1
done

if [[ "${OK:-0}" -ne 1 ]]; then
  echo "!! Odoo did not respond in time. Recent log tail:"
  docker logs --tail 200 odoo || true
  exit 1
fi

echo
echo "✅ Done!"
echo "Open locally:  http://localhost:${HOST_HTTP_PORT}/web?db=${DB_NAME}"
echo "Default login: admin / admin    (change it after first login)"
echo "DB Manager (master) password: ${MASTER_PASSWORD}"
