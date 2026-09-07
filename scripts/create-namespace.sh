#!/bin/sh
# Creates the default namespace on a cluster once its frontend is reachable.
#
# The frontend authenticates callers by client certificate, so that is all this
# needs. It used to mint a Keycloak JWT as well, back when the server ran a JWT
# authorizer; replication traffic has no token to present, so that authorizer
# is gone and certificates are the only credential the frontend accepts.
set -eu

NAMESPACE=${DEFAULT_NAMESPACE:-default}
TEMPORAL_ADDRESS=${TEMPORAL_ADDRESS:-temporal:7233}
MAX_ATTEMPTS=${TEMPORAL_HEALTH_CHECK_MAX_ATTEMPTS:-30}
SLEEP_SECONDS=${TEMPORAL_HEALTH_CHECK_SLEEP_SECONDS:-5}

: "${TEMPORAL_TLS_CA_PATH:?TEMPORAL_TLS_CA_PATH must be set}"
: "${TEMPORAL_TLS_CERT_PATH:?TEMPORAL_TLS_CERT_PATH must be set}"
: "${TEMPORAL_TLS_KEY_PATH:?TEMPORAL_TLS_KEY_PATH must be set}"

# Passed explicitly rather than relying on the CLI picking the TEMPORAL_TLS_*
# variables up, so the flags stay visible in `set -x` output when something
# goes wrong.
TLS_ARGS="--tls --tls-ca-path $TEMPORAL_TLS_CA_PATH \
  --tls-cert-path $TEMPORAL_TLS_CERT_PATH \
  --tls-key-path $TEMPORAL_TLS_KEY_PATH \
  --tls-server-name ${TEMPORAL_TLS_SERVER_NAME:-temporal}"

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
while ! temporal operator cluster health --address "$TEMPORAL_ADDRESS" $TLS_ARGS; do
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
  if temporal operator namespace describe -n "$NAMESPACE" \
      --address "$TEMPORAL_ADDRESS" $TLS_ARGS >/dev/null 2>&1; then
    echo "Namespace '$NAMESPACE' already exists"
    break
  fi

  if temporal operator namespace create -n "$NAMESPACE" \
      --address "$TEMPORAL_ADDRESS" $TLS_ARGS >/dev/null 2>&1; then
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
