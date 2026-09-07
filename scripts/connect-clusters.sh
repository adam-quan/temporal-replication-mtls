#!/usr/bin/env bash
#
# Joins cluster-a and cluster-b into a replication pair and creates a global
# namespace that lives on both.
#
# Run from the repo root, after both stacks are up:
#
#   docker compose up -d
#   docker compose -f docker-compose.cluster-b.yml up -d
#   ./scripts/connect-clusters.sh
#
# Everything here talks to each cluster's frontend over mTLS, which is also the
# address the clusters register for each other - so what this script exercises
# is the same path replication itself will use.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
NETWORK=${NETWORK:-temporal-network}
ADMIN_TOOLS_IMAGE=${ADMIN_TOOLS_IMAGE:-temporalio/admin-tools:1.31.0}

A_ADDR=${A_ADDR:-temporal:7233}
B_ADDR=${B_ADDR:-temporal-b:7233}
A_SERVER_NAME=${A_SERVER_NAME:-temporal}
B_SERVER_NAME=${B_SERVER_NAME:-temporal-b}
GLOBAL_NAMESPACE=${GLOBAL_NAMESPACE:-replicated}

# temporal <cluster-a|cluster-b> <args...>
tctl() {
  cluster=$1; shift
  case $cluster in
    cluster-a) addr=$A_ADDR; name=$A_SERVER_NAME ;;
    cluster-b) addr=$B_ADDR; name=$B_SERVER_NAME ;;
    *) echo "unknown cluster: $cluster" >&2; return 1 ;;
  esac
  docker run --rm --network "$NETWORK" \
    -v "$ROOT_DIR/certs:/certs:ro" \
    "$ADMIN_TOOLS_IMAGE" temporal "$@" \
    --address "$addr" \
    --tls \
    --tls-ca-path /certs/ca/ca.pem \
    --tls-cert-path "/certs/$cluster/client.pem" \
    --tls-key-path "/certs/$cluster/client.key" \
    --tls-server-name "$name"
}

wait_for() {
  cluster=$1
  echo "Waiting for $cluster frontend..."
  for _ in $(seq 1 60); do
    if tctl "$cluster" operator cluster health >/dev/null 2>&1; then
      echo "  $cluster is up"
      return 0
    fi
    sleep 5
  done
  echo "  $cluster did not become reachable" >&2
  return 1
}

wait_for cluster-a
wait_for cluster-b

# Each side registers the other. --enable-connection turns on the replication
# stream; without it the clusters know about each other but move no data.
echo "Registering cluster-b with cluster-a..."
tctl cluster-a operator cluster upsert --frontend-address "$B_ADDR" --enable-connection

echo "Registering cluster-a with cluster-b..."
tctl cluster-b operator cluster upsert --frontend-address "$A_ADDR" --enable-connection

echo
echo "cluster-a sees:"
tctl cluster-a operator cluster list
echo "cluster-b sees:"
tctl cluster-b operator cluster list

# A global namespace is created once, on its active cluster, and propagates to
# the other side over the replication stream a moment later.
#
# The retry is not decoration: each frontend caches the cluster list and
# refreshes it on system.clusterMetadataRefreshInterval (a minute by default),
# so for a short window after the upsert above, cluster-a still rejects
# cluster-b with "Invalid cluster name".
echo
if tctl cluster-a operator namespace describe -n "$GLOBAL_NAMESPACE" >/dev/null 2>&1; then
  echo "Global namespace '$GLOBAL_NAMESPACE' already exists"
else
  echo "Creating global namespace '$GLOBAL_NAMESPACE' (active: cluster-a)..."
  for attempt in $(seq 1 18); do
    if tctl cluster-a operator namespace create \
        -n "$GLOBAL_NAMESPACE" \
        --global \
        --cluster cluster-a \
        --cluster cluster-b \
        --active-cluster cluster-a 2>&1 | tee /tmp/xdc-ns-create.log; then
      break
    fi
    if ! grep -q "Invalid cluster name" /tmp/xdc-ns-create.log; then
      echo "  namespace creation failed" >&2
      exit 1
    fi
    echo "  cluster list not refreshed on cluster-a yet, retrying ($attempt/18)..."
    sleep 10
  done
fi

echo
echo "Waiting for '$GLOBAL_NAMESPACE' to replicate to cluster-b..."
for _ in $(seq 1 30); do
  if tctl cluster-b operator namespace describe -n "$GLOBAL_NAMESPACE" >/dev/null 2>&1; then
    echo "  replicated"
    tctl cluster-b operator namespace describe -n "$GLOBAL_NAMESPACE"
    exit 0
  fi
  sleep 5
done

echo "  '$GLOBAL_NAMESPACE' has not appeared on cluster-b yet; check the server logs" >&2
exit 1
