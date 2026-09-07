#!/bin/sh
set -eu

NAMESPACE=${DEFAULT_NAMESPACE:-default}
TEMPORAL_ADDRESS=${TEMPORAL_ADDRESS:-temporal:7233}
MAX_ATTEMPTS=${TEMPORAL_HEALTH_CHECK_MAX_ATTEMPTS:-30}
SLEEP_SECONDS=${TEMPORAL_HEALTH_CHECK_SLEEP_SECONDS:-5}

# The server runs with JWT authorization enabled, so every operator call below
# needs a bearer token. Mint one with the client credentials grant, which
# authenticates as the Keycloak client's service account.
KEYCLOAK_URL=${KEYCLOAK_URL:-http://keycloak:9080}
KEYCLOAK_REALM=${KEYCLOAK_REALM:-temporal}
KEYCLOAK_CLIENT_ID=${KEYCLOAK_CLIENT_ID:-temporal-app}
: "${KEYCLOAK_CLIENT_SECRET:?KEYCLOAK_CLIENT_SECRET must be set (see .env)}"

TOKEN_ENDPOINT="$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token"

# The frontend requires a client certificate as well as a JWT, so every CLI
# call below carries both. Passed explicitly rather than relying on the CLI
# picking the TEMPORAL_TLS_* variables up, so the flags stay visible in `set -x`
# output when something goes wrong.
TLS_ARGS=""
if [ -n "${TEMPORAL_TLS_CA_PATH:-}" ]; then
  TLS_ARGS="--tls --tls-ca-path $TEMPORAL_TLS_CA_PATH \
    --tls-cert-path $TEMPORAL_TLS_CERT_PATH \
    --tls-key-path $TEMPORAL_TLS_KEY_PATH \
    --tls-server-name ${TEMPORAL_TLS_SERVER_NAME:-temporal}"
fi

# Prints a fresh access token on success and nothing on failure, so callers can
# retry while Keycloak is still starting up. Only wget/sed are available in the
# admin-tools image, hence no curl or jq.
fetch_token() {
  response=$(wget -q -O - \
    --header='Content-Type: application/x-www-form-urlencoded' \
    --post-data="grant_type=client_credentials&client_id=$KEYCLOAK_CLIENT_ID&client_secret=$KEYCLOAK_CLIENT_SECRET" \
    "$TOKEN_ENDPOINT" 2>/dev/null) || return 0
  printf '%s' "$response" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

echo 'Waiting for Keycloak to issue a token...'
attempt=1
while :; do
  TOKEN=$(fetch_token)
  if [ -n "$TOKEN" ]; then
    echo 'Obtained JWT from Keycloak'
    break
  fi

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "Could not obtain a JWT from Keycloak after $MAX_ATTEMPTS attempts"
    exit 1
  fi

  echo "Keycloak not ready yet, waiting... (attempt $attempt/$MAX_ATTEMPTS)"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done

echo "Waiting for Temporal server port to be available..."
SERVER_HOST=$(echo "$TEMPORAL_ADDRESS" | cut -d: -f1)
SERVER_PORT=$(echo "$TEMPORAL_ADDRESS" | cut -d: -f2)
attempt=1
while ! nc -z -w 10 "$SERVER_HOST" "$SERVER_PORT"; do
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "Temporal server port did not become available after $MAX_ATTEMPTS attempts"
    exit 1
  fi

  echo "Temporal server port not ready yet, waiting... (attempt $attempt/$MAX_ATTEMPTS)"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done
echo 'Temporal server port is available'

echo 'Waiting for Temporal server to be healthy...'
attempt=1

while :; do
  # Re-mint the token on each attempt; access tokens are short lived and this
  # loop can outlast one.
  TOKEN=$(fetch_token)
  if [ -n "$TOKEN" ] && temporal operator cluster health \
      --address "$TEMPORAL_ADDRESS" $TLS_ARGS \
      --grpc-meta authorization="Bearer $TOKEN"; then
    break
  fi

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "Server did not become healthy after $MAX_ATTEMPTS attempts"
    exit 1
  fi

  echo "Server not ready yet, waiting... (attempt $attempt/$MAX_ATTEMPTS)"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done

echo "Server is healthy, creating namespace '$NAMESPACE'..."

attempt=1
while :; do
  TOKEN=$(fetch_token)

  if [ -n "$TOKEN" ] && temporal operator namespace describe -n "$NAMESPACE" \
      --address "$TEMPORAL_ADDRESS" $TLS_ARGS \
      --grpc-meta authorization="Bearer $TOKEN" >/dev/null 2>&1; then
    echo "Namespace '$NAMESPACE' already exists"
    break
  fi

  if [ -n "$TOKEN" ] && temporal operator namespace create -n "$NAMESPACE" \
      --address "$TEMPORAL_ADDRESS" $TLS_ARGS \
      --grpc-meta authorization="Bearer $TOKEN" >/dev/null 2>&1; then
    echo "Namespace '$NAMESPACE' created"
    break
  fi

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "Failed to create namespace '$NAMESPACE' after $MAX_ATTEMPTS attempts"
    exit 1
  fi

  echo "Namespace operation not ready yet, waiting... (attempt $attempt/$MAX_ATTEMPTS)"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done
