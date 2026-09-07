#!/usr/bin/env bash
# Creates the Keycloak realm, client, role, claim mapper and user that the
# Temporal server in docker-compose.yml expects. Replaces clicking through the
# Keycloak admin console by hand.
#
# Run it against a Keycloak that is already up:
#   docker compose up keycloak -d
#   ./scripts/setup-keycloak.sh
#
# The client secret Keycloak generates is written to KEYCLOAK_CLIENT_SECRET in
# .env, which is what docker-compose.yml reads it from.
#
# Every step is idempotent, so re-running it is safe.
set -euo pipefail

KEYCLOAK_URL=${KEYCLOAK_URL:-http://localhost:9080}
KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN:-admin}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD:-admin}

REALM=${KEYCLOAK_REALM:-temporal}
CLIENT_ID=${KEYCLOAK_CLIENT_ID:-temporal-app}
REDIRECT_URI=${KEYCLOAK_REDIRECT_URI:-http://localhost:8080/*}
ROLE_NAME=${KEYCLOAK_ROLE_NAME:-temporal-system:admin}
MAPPER_NAME=${KEYCLOAK_MAPPER_NAME:-temporal-permissions-mapper}
CLAIM_NAME=${KEYCLOAK_CLAIM_NAME:-permissions}
USER_NAME=${KEYCLOAK_USER:-temporal-user}
USER_PASSWORD=${KEYCLOAK_USER_PASSWORD:-temporal}
USER_EMAIL=${KEYCLOAK_USER_EMAIL:-temporal-user@example.com}
USER_FIRST_NAME=${KEYCLOAK_USER_FIRST_NAME:-Temporal}
USER_LAST_NAME=${KEYCLOAK_USER_LAST_NAME:-User}

MAX_ATTEMPTS=${KEYCLOAK_MAX_ATTEMPTS:-30}
SLEEP_SECONDS=${KEYCLOAK_SLEEP_SECONDS:-2}

# The .env the client secret is written to, resolved relative to this script so
# the script works from any directory. Set ENV_FILE='' to skip the write.
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENV_FILE=${ENV_FILE-$REPO_ROOT/.env}
ENV_EXAMPLE=${ENV_EXAMPLE-$REPO_ROOT/.env.example}

command -v curl >/dev/null || { echo 'curl is required' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 is required (used to read JSON responses)' >&2; exit 1; }

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

# --- JSON helpers -----------------------------------------------------------
# Reads a top-level field. If the response is an array, the first element wins.
json_get() {
  python3 -c '
import json, sys
key = sys.argv[1]
d = json.load(sys.stdin)
if isinstance(d, list):
    d = d[0] if d else {}
v = d.get(key, "")
print(v if isinstance(v, str) else json.dumps(v))
' "$1"
}

# Prints the "id" of the array element whose <field> equals <value>, if any.
json_id_where() {
  python3 -c '
import json, sys
field, value = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)
for item in (d if isinstance(d, list) else [d]):
    if item.get(field) == value:
        print(item.get("id", ""))
        break
' "$1" "$2"
}

# --- Admin API helpers ------------------------------------------------------
# Calls the admin REST API and prints the HTTP status; the response body lands
# in $BODY so callers can parse it.
api() {
  local method=$1 path=$2 data=${3:-}
  local args=(-sS -o "$BODY" -w '%{http_code}' -X "$method"
              -H "Authorization: Bearer $TOKEN"
              "$KEYCLOAK_URL/admin/realms$path")
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' -d "$data")
  curl "${args[@]}"
}

# Fails the script unless the status is one of the accepted ones.
expect() {
  local status=$1; shift
  for ok in "$@"; do
    [ "$status" = "$ok" ] && return 0
  done
  echo "Unexpected HTTP $status from Keycloak: $(cat "$BODY")" >&2
  exit 1
}

fetch_admin_token() {
  curl -sS -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password&client_id=admin-cli&username=$KEYCLOAK_ADMIN&password=$KEYCLOAK_ADMIN_PASSWORD" \
    "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" 2>/dev/null |
    json_get access_token
}

echo "Waiting for Keycloak at $KEYCLOAK_URL..."
attempt=1
while :; do
  TOKEN=$(fetch_admin_token || true)
  if [ -n "${TOKEN:-}" ]; then
    echo 'Authenticated against the master realm'
    break
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "Could not authenticate as '$KEYCLOAK_ADMIN' after $MAX_ATTEMPTS attempts" >&2
    exit 1
  fi
  echo "Keycloak not ready yet, waiting... (attempt $attempt/$MAX_ATTEMPTS)"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done

# --- 1. Realm ---------------------------------------------------------------
status=$(api GET "/$REALM")
if [ "$status" = 200 ]; then
  echo "Realm '$REALM' already exists"
else
  expect "$status" 404
  status=$(api POST "" "$(printf '{"realm":"%s","enabled":true}' "$REALM")")
  expect "$status" 201
  echo "Created realm '$REALM'"
fi

# --- 2. Client --------------------------------------------------------------
# Confidential OpenID Connect client: client authentication on, direct access
# grants and service accounts enabled.
CLIENT_JSON=$(python3 -c '
import json, sys
client_id, redirect_uri = sys.argv[1], sys.argv[2]
print(json.dumps({
    "clientId": client_id,
    "protocol": "openid-connect",
    "enabled": True,
    "publicClient": False,            # Client authentication: On
    "clientAuthenticatorType": "client-secret",
    "standardFlowEnabled": True,
    "directAccessGrantsEnabled": True,  # Direct access grants
    "serviceAccountsEnabled": True,     # Service accounts roles
    "redirectUris": [redirect_uri],
}))
' "$CLIENT_ID" "$REDIRECT_URI")

status=$(api GET "/$REALM/clients?clientId=$CLIENT_ID")
expect "$status" 200
CLIENT_UUID=$(json_id_where clientId "$CLIENT_ID" <"$BODY")

if [ -n "$CLIENT_UUID" ]; then
  status=$(api PUT "/$REALM/clients/$CLIENT_UUID" "$CLIENT_JSON")
  expect "$status" 204
  echo "Client '$CLIENT_ID' already exists, settings reapplied"
else
  status=$(api POST "/$REALM/clients" "$CLIENT_JSON")
  expect "$status" 201
  status=$(api GET "/$REALM/clients?clientId=$CLIENT_ID")
  expect "$status" 200
  CLIENT_UUID=$(json_id_where clientId "$CLIENT_ID" <"$BODY")
  echo "Created client '$CLIENT_ID'"
fi
[ -n "$CLIENT_UUID" ] || { echo "Could not resolve the internal id of client '$CLIENT_ID'" >&2; exit 1; }

# --- 3. Client role ---------------------------------------------------------
status=$(api GET "/$REALM/clients/$CLIENT_UUID/roles")
expect "$status" 200
if [ -n "$(json_id_where name "$ROLE_NAME" <"$BODY")" ]; then
  echo "Client role '$ROLE_NAME' already exists"
else
  status=$(api POST "/$REALM/clients/$CLIENT_UUID/roles" \
    "$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1]}))' "$ROLE_NAME")")
  expect "$status" 201
  echo "Created client role '$ROLE_NAME'"
fi

status=$(api GET "/$REALM/clients/$CLIENT_UUID/roles")
expect "$status" 200
ROLE_ID=$(json_id_where name "$ROLE_NAME" <"$BODY")
[ -n "$ROLE_ID" ] || { echo "Could not resolve client role '$ROLE_NAME'" >&2; exit 1; }

ROLE_ASSIGNMENT=$(python3 -c '
import json, sys
print(json.dumps([{"id": sys.argv[1], "name": sys.argv[2]}]))
' "$ROLE_ID" "$ROLE_NAME")

# --- 4. Permissions mapper --------------------------------------------------
# Lives on the client's dedicated (default) scope, which the admin API models
# as the client's own protocol mappers. Temporal's default claim mapper reads
# the roles out of the "permissions" claim of the access token.
MAPPER_JSON=$(python3 -c '
import json, sys
mapper_name, client_id, claim_name = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "name": mapper_name,
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-client-role-mapper",
    "config": {
        "usermodel.clientRoleMapping.clientId": client_id,
        "claim.name": claim_name,
        "jsonType.label": "String",
        "multivalued": "true",
        "access.token.claim": "true",
        "id.token.claim": "true",
        "userinfo.token.claim": "true",
        "introspection.token.claim": "true",
    },
}))
' "$MAPPER_NAME" "$CLIENT_ID" "$CLAIM_NAME")

status=$(api GET "/$REALM/clients/$CLIENT_UUID/protocol-mappers/models")
expect "$status" 200
MAPPER_ID=$(json_id_where name "$MAPPER_NAME" <"$BODY")

if [ -n "$MAPPER_ID" ]; then
  status=$(api PUT "/$REALM/clients/$CLIENT_UUID/protocol-mappers/models/$MAPPER_ID" \
    "$(python3 -c '
import json, sys
m = json.loads(sys.argv[1]); m["id"] = sys.argv[2]; print(json.dumps(m))
' "$MAPPER_JSON" "$MAPPER_ID")")
  expect "$status" 204
  echo "Mapper '$MAPPER_NAME' already exists, config reapplied"
else
  status=$(api POST "/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" "$MAPPER_JSON")
  expect "$status" 201
  echo "Created mapper '$MAPPER_NAME' emitting the '$CLAIM_NAME' claim"
fi

# --- 5. Grant the role to the client's service account ----------------------
status=$(api GET "/$REALM/clients/$CLIENT_UUID/service-account-user")
expect "$status" 200
SERVICE_ACCOUNT_ID=$(json_get id <"$BODY")
[ -n "$SERVICE_ACCOUNT_ID" ] || { echo "Client '$CLIENT_ID' has no service account user" >&2; exit 1; }

status=$(api POST "/$REALM/users/$SERVICE_ACCOUNT_ID/role-mappings/clients/$CLIENT_UUID" "$ROLE_ASSIGNMENT")
expect "$status" 204 409
echo "Service account of '$CLIENT_ID' has client role '$ROLE_NAME'"

# --- 6. User ----------------------------------------------------------------
# The realm's default user profile marks email/first/last name as required, so
# they are filled in here; without them Keycloak leaves a pending required
# action and rejects logins with "Account is not fully set up".
USER_JSON=$(python3 -c '
import json, sys
username, email, first, last = sys.argv[1:5]
print(json.dumps({
    "username": username,
    "enabled": True,
    "email": email,
    "emailVerified": True,
    "firstName": first,
    "lastName": last,
    "requiredActions": [],
}))
' "$USER_NAME" "$USER_EMAIL" "$USER_FIRST_NAME" "$USER_LAST_NAME")

status=$(api GET "/$REALM/users?username=$USER_NAME&exact=true")
expect "$status" 200
USER_UUID=$(json_id_where username "$USER_NAME" <"$BODY")

if [ -z "$USER_UUID" ]; then
  status=$(api POST "/$REALM/users" "$USER_JSON")
  expect "$status" 201
  status=$(api GET "/$REALM/users?username=$USER_NAME&exact=true")
  expect "$status" 200
  USER_UUID=$(json_id_where username "$USER_NAME" <"$BODY")
  echo "Created user '$USER_NAME'"
else
  status=$(api PUT "/$REALM/users/$USER_UUID" "$USER_JSON")
  expect "$status" 204
  echo "User '$USER_NAME' already exists, profile reapplied"
fi
[ -n "$USER_UUID" ] || { echo "Could not resolve user '$USER_NAME'" >&2; exit 1; }

status=$(api PUT "/$REALM/users/$USER_UUID/reset-password" \
  "$(python3 -c '
import json, sys
print(json.dumps({"type": "password", "value": sys.argv[1], "temporary": False}))
' "$USER_PASSWORD")")
expect "$status" 204
echo "Set the password for '$USER_NAME'"

status=$(api POST "/$REALM/users/$USER_UUID/role-mappings/clients/$CLIENT_UUID" "$ROLE_ASSIGNMENT")
expect "$status" 204 409
echo "User '$USER_NAME' has client role '$ROLE_NAME'"

# --- Client secret ----------------------------------------------------------
status=$(api GET "/$REALM/clients/$CLIENT_UUID/client-secret")
expect "$status" 200
CLIENT_SECRET=$(json_get value <"$BODY")
[ -n "$CLIENT_SECRET" ] || { echo "Keycloak returned an empty client secret" >&2; exit 1; }

# The rest of the stack reads the secret from .env, so write it there. Set
# ENV_FILE to an empty string to skip this and only print the secret.
if [ -n "$ENV_FILE" ]; then
  # No .bak file is written on purpose: .gitignore covers ".env" but not
  # ".env.bak", so a backup could end up committed with the secret in it.
  CLIENT_SECRET="$CLIENT_SECRET" ENV_FILE="$ENV_FILE" ENV_EXAMPLE="$ENV_EXAMPLE" python3 <<'PYTHON'
import os, sys, tempfile

path = os.environ["ENV_FILE"]
example = os.environ["ENV_EXAMPLE"]
secret = os.environ["CLIENT_SECRET"]
key = "KEYCLOAK_CLIENT_SECRET"
line = f"{key}={secret}"

if os.path.exists(path):
    with open(path) as f:
        text = f.read()
    origin = None
elif os.path.exists(example):
    with open(example) as f:
        text = f.read()
    origin = example
else:
    text = ""
    origin = "scratch"

lines = text.splitlines()
replaced = False
for i, existing in enumerate(lines):
    if existing.split("=", 1)[0].strip() == key:
        if existing == line:
            print(f"{path} already has the current client secret")
            sys.exit(0)
        lines[i] = line
        replaced = True
        break

if not replaced:
    lines.append(line)

# Written through a temp file in the same directory so an interrupted run
# cannot leave a half-written .env behind.
directory = os.path.dirname(os.path.abspath(path)) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".env.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except BaseException:
    os.unlink(tmp)
    raise

if origin == "scratch":
    print(f"Created {path} with {key}")
elif origin:
    print(f"Created {path} from {origin} and set {key}")
elif replaced:
    print(f"Updated {key} in {path}")
else:
    print(f"Added {key} to {path}")
PYTHON
fi

cat <<EOF

Keycloak setup complete.

Client secret: $CLIENT_SECRET
EOF

if [ -n "$ENV_FILE" ]; then
  echo "It is set as KEYCLOAK_CLIENT_SECRET in $ENV_FILE."
else
  echo "Set it as KEYCLOAK_CLIENT_SECRET in your .env before starting the stack."
fi

cat <<EOF

Then run: docker compose up -d
Log in to the Temporal UI at http://localhost:8080 as $USER_NAME / $USER_PASSWORD
EOF
