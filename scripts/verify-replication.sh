#!/usr/bin/env bash
#
# Verifies that cross-cluster replication is working AND that mTLS is actually
# doing something, rather than TLS being configured but not enforced.
#
#   ./scripts/verify-replication.sh              # everything except failover
#   ./scripts/verify-replication.sh --failover   # also fail over and back
#   ./scripts/verify-replication.sh --help
#
# Checks are grouped into seven sections. Negative checks matter as much as
# positive ones here: a frontend that accepts a connection without a client
# certificate is misconfigured even though every positive test still passes.
#
# Exit status is 0 only if every check passed.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CERTS_DIR=${CERTS_DIR:-$ROOT_DIR/certs}
NETWORK=${NETWORK:-temporal-network}
IMAGE=${ADMIN_TOOLS_IMAGE:-temporalio/admin-tools:1.31.0}
NAMESPACE=${GLOBAL_NAMESPACE:-replicated}

# Frontends, as seen from inside the Docker network. This is the address the
# clusters register for each other, so it is the replication path too.
A_ADDR=${A_ADDR:-temporal:7233}
B_ADDR=${B_ADDR:-temporal-b:7233}
A_SN=${A_SN:-temporal}
B_SN=${B_SN:-temporal-b}

# The same frontends as published on the host.
A_PUBLIC=${A_PUBLIC:-localhost:7233}
B_PUBLIC=${B_PUBLIC:-localhost:8233}
A_PUBLIC_SN=${A_PUBLIC_SN:-temporal}
B_PUBLIC_SN=${B_PUBLIC_SN:-temporal-b}

DO_FAILOVER=false
KEEP_PROBE=false
for arg in "$@"; do
  case $arg in
    --failover) DO_FAILOVER=true ;;
    --keep) KEEP_PROBE=true ;;
    -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- output ------------------------------------------------------------------

if [ -t 1 ]; then
  RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m')
  YELLOW=$(printf '\033[33m'); BOLD=$(printf '\033[1m'); RESET=$(printf '\033[0m')
else
  RED=; GREEN=; YELLOW=; BOLD=; RESET=
fi

PASSED=0
FAILED=0
SKIPPED=0

section() { printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$RESET"; }
pass()    { PASSED=$((PASSED+1)); printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
skip()    { SKIPPED=$((SKIPPED+1)); printf '  %sSKIP%s %s\n' "$YELLOW" "$RESET" "$1"; }
note()    { printf '       %s\n' "$1"; }
fail() {
  FAILED=$((FAILED+1))
  printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"
  [ $# -gt 1 ] && printf '       %s\n' "$2"
  return 0
}

# check <description> <expected-substring> <command...>
# Passes when the command succeeds and its output contains the substring.
# An empty substring means "just has to succeed".
check() {
  desc=$1; expect=$2; shift 2
  out=$("$@" 2>&1)
  if [ $? -ne 0 ]; then
    fail "$desc" "command failed: $(printf '%s' "$out" | tail -1)"
  elif [ -n "$expect" ] && ! printf '%s' "$out" | grep -qF -- "$expect"; then
    fail "$desc" "expected to find '$expect' in: $(printf '%s' "$out" | tail -1)"
  else
    pass "$desc"
  fi
}

# check_rejected <description> <expected-error-regex> <command...>
# Passes only when the command FAILS with a matching error. A command that
# unexpectedly succeeds is the interesting failure: it means an access control
# that should be there is not.
#
# The pattern is an extended regex rather than a fixed string because a rejected
# TLS handshake surfaces differently depending on which side notices first - the
# client may read the server's "certificate required" alert, or it may just find
# its own write has become a broken pipe. Both are the same rejection.
check_rejected() {
  desc=$1; expect=$2; shift 2
  out=$("$@" 2>&1)
  if [ $? -eq 0 ]; then
    fail "$desc" "the call SUCCEEDED when it should have been rejected"
  elif [ -n "$expect" ] && ! printf '%s' "$out" | grep -qiE -- "$expect"; then
    fail "$desc" "rejected, but not as expected ($expect): $(printf '%s' "$out" | tail -1)"
  else
    pass "$desc"
  fi
}

# Ways a handshake refused for want of a client certificate can present itself.
TLS_REFUSED='certificate required|bad certificate|handshake|broken pipe|connection reset|EOF|connection closed'

# --- CLI wrappers ------------------------------------------------------------

# Full mTLS against a cluster's frontend, using that cluster's client
# certificate.
cli() {
  cluster=$1; shift
  case $cluster in
    cluster-a) addr=$A_ADDR; sn=$A_SN ;;
    cluster-b) addr=$B_ADDR; sn=$B_SN ;;
    *) echo "unknown cluster: $cluster" >&2; return 2 ;;
  esac
  docker run --rm --network "$NETWORK" -v "$CERTS_DIR:/certs:ro" "$IMAGE" temporal "$@" \
    --address "$addr" --tls \
    --tls-ca-path /certs/ca/ca.pem \
    --tls-cert-path "/certs/$cluster/client.pem" \
    --tls-key-path "/certs/$cluster/client.key" \
    --tls-server-name "$sn"
}

# TLS, but no client certificate.
cli_nocert() {
  addr=$1; sn=$2; shift 2
  docker run --rm --network "$NETWORK" -v "$CERTS_DIR:/certs:ro" "$IMAGE" temporal "$@" \
    --address "$addr" --tls --tls-ca-path /certs/ca/ca.pem --tls-server-name "$sn"
}

# No TLS at all.
cli_plaintext() {
  addr=$1; shift
  docker run --rm --network "$NETWORK" "$IMAGE" temporal "$@" --address "$addr" --tls=false
}

# A well-formed client certificate signed by somebody else's CA.
cli_foreigncert() {
  addr=$1; sn=$2; shift 2
  docker run --rm --network "$NETWORK" \
    -v "$CERTS_DIR:/certs:ro" -v "$FOREIGN_DIR:/foreign:ro" "$IMAGE" temporal "$@" \
    --address "$addr" --tls --tls-ca-path /certs/ca/ca.pem \
    --tls-cert-path /foreign/foreign.pem --tls-key-path /foreign/foreign.key \
    --tls-server-name "$sn"
}

# Public frontend, with the client certificate but no JWT.
cli_public() {
  cluster=$1; shift
  case $cluster in
    cluster-a) addr=$A_PUBLIC; sn=$A_PUBLIC_SN ;;
    cluster-b) addr=$B_PUBLIC; sn=$B_PUBLIC_SN ;;
  esac
  docker run --rm --network host -v "$CERTS_DIR:/certs:ro" "$IMAGE" temporal "$@" \
    --address "$addr" --tls \
    --tls-ca-path /certs/ca/ca.pem \
    --tls-cert-path "/certs/$cluster/client.pem" \
    --tls-key-path "/certs/$cluster/client.key" \
    --tls-server-name "$sn"
}

# jget <json-path> - reads stdin, prints the value at a dotted path, or nothing.
jget() {
  python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for part in sys.argv[1].split("."):
    if isinstance(doc, list):
        try: doc = doc[int(part)]
        except (ValueError, IndexError): sys.exit(0)
    elif isinstance(doc, dict) and part in doc:
        doc = doc[part]
    else:
        sys.exit(0)
print(doc if not isinstance(doc, (dict, list)) else json.dumps(doc))
' "$1"
}

cleanup() {
  [ -n "${FOREIGN_DIR:-}" ] && rm -rf "$FOREIGN_DIR"
}
trap cleanup EXIT

# =============================================================================
printf '%sVerifying cross-cluster replication over mTLS%s\n' "$BOLD" "$RESET"
note "namespace: $NAMESPACE   network: $NETWORK   certs: $CERTS_DIR"

# --- 1. PKI ------------------------------------------------------------------
section "1. Certificates"

if [ ! -f "$CERTS_DIR/ca/ca.pem" ]; then
  fail "root CA present" "$CERTS_DIR/ca/ca.pem not found - run ./scripts/generate-certs.sh"
else
  pass "root CA present"

  for cluster in cluster-a cluster-b; do
    for leaf in internode frontend client; do
      f=$CERTS_DIR/$cluster/$leaf.pem
      if [ ! -f "$f" ]; then
        fail "$cluster/$leaf.pem exists"
        continue
      fi
      if openssl verify -CAfile "$CERTS_DIR/ca/ca.pem" "$f" >/dev/null 2>&1; then
        pass "$cluster/$leaf.pem chains to the root CA"
      else
        fail "$cluster/$leaf.pem chains to the root CA"
      fi
      if openssl x509 -in "$f" -noout -checkend 86400 >/dev/null 2>&1; then
        :
      else
        fail "$cluster/$leaf.pem is valid for at least another day"
      fi
    done

    # The internode certificate is used in both directions - as the internal
    # frontend's server certificate, and as the client certificate this cluster
    # presents to its peer - so it needs both extended key usages.
    eku=$(openssl x509 -in "$CERTS_DIR/$cluster/internode.pem" -noout -ext extendedKeyUsage 2>/dev/null)
    if printf '%s' "$eku" | grep -q "Server Authentication" && \
       printf '%s' "$eku" | grep -q "Client Authentication"; then
      pass "$cluster/internode.pem has both serverAuth and clientAuth"
    else
      fail "$cluster/internode.pem has both serverAuth and clientAuth" "got: $eku"
    fi
  done

  # Each internode certificate must carry the name this cluster's own services
  # pin as serverName, or intra-cluster host verification fails at handshake
  # time.
  for pair in "cluster-a temporal-a.internal" "cluster-b temporal-b.internal"; do
    set -- $pair
    if openssl x509 -in "$CERTS_DIR/$1/internode.pem" -noout -ext subjectAltName 2>/dev/null \
       | grep -q "DNS:$2"; then
      pass "$1/internode.pem covers the pinned serverName '$2'"
    else
      fail "$1/internode.pem covers the pinned serverName '$2'"
    fi
  done

  # And each frontend certificate must cover the name the *peer cluster* pins,
  # since replication now terminates on the frontend.
  for pair in "cluster-a $A_SN" "cluster-b $B_SN"; do
    set -- $pair
    if openssl x509 -in "$CERTS_DIR/$1/frontend.pem" -noout -ext subjectAltName 2>/dev/null \
       | grep -q "DNS:$2"; then
      pass "$1/frontend.pem covers '$2', the name its peer pins for replication"
    else
      fail "$1/frontend.pem covers '$2', the name its peer pins for replication"
    fi
  done
fi

# --- 2. mTLS on the replication endpoint -------------------------------------
section "2. mTLS on the frontend (the replication endpoint)"

check "cluster-a accepts a valid client certificate" "cluster-a" \
  cli cluster-a operator cluster describe
check "cluster-b accepts a valid client certificate" "cluster-b" \
  cli cluster-b operator cluster describe

check_rejected "cluster-a rejects a client with no certificate" "$TLS_REFUSED" \
  cli_nocert "$A_ADDR" "$A_SN" operator cluster describe
check_rejected "cluster-b rejects a client with no certificate" "$TLS_REFUSED" \
  cli_nocert "$B_ADDR" "$B_SN" operator cluster describe

check_rejected "cluster-a rejects plaintext gRPC" "" \
  cli_plaintext "$A_ADDR" operator cluster describe
check_rejected "cluster-b rejects plaintext gRPC" "" \
  cli_plaintext "$B_ADDR" operator cluster describe

# A certificate signed by an untrusted CA proves clientCaFiles is constraining
# who may connect, not merely that *some* certificate is required.
FOREIGN_DIR=$(mktemp -d)
if openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
     -keyout "$FOREIGN_DIR/foreign.key" -out "$FOREIGN_DIR/foreign.pem" \
     -subj "/CN=not-your-ca" -addext "extendedKeyUsage=clientAuth" >/dev/null 2>&1; then
  chmod 644 "$FOREIGN_DIR"/foreign.key
  check_rejected "cluster-a rejects a certificate from an untrusted CA" "$TLS_REFUSED" \
    cli_foreigncert "$A_ADDR" "$A_SN" operator cluster describe
  check_rejected "cluster-b rejects a certificate from an untrusted CA" "$TLS_REFUSED" \
    cli_foreigncert "$B_ADDR" "$B_SN" operator cluster describe
else
  skip "untrusted-CA rejection (could not generate a throwaway certificate)"
fi

# --- 3. The public frontend keeps both doors locked ---------------------------
section "3. The frontend as published on the host"

for pair in "cluster-a $A_PUBLIC $A_PUBLIC_SN" "cluster-b $B_PUBLIC $B_PUBLIC_SN"; do
  set -- $pair
  cluster=$1; addr=$2; sn=$3

  # Served certificate identity, straight off the wire.
  subject=$(echo | openssl s_client -connect "$addr" -servername "$sn" \
              -CAfile "$CERTS_DIR/ca/ca.pem" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
  if printf '%s' "$subject" | grep -q "CN=$sn"; then
    pass "$cluster serves a frontend certificate for '$sn'"
  else
    fail "$cluster serves a frontend certificate for '$sn'" "got: ${subject:-<no certificate>}"
  fi

  # A server that asks for a client certificate advertises which CAs it accepts.
  if echo | openssl s_client -connect "$addr" -servername "$sn" \
       -CAfile "$CERTS_DIR/ca/ca.pem" 2>&1 | grep -q "Acceptable client certificate CA names"; then
    pass "$cluster requests a client certificate"
  else
    fail "$cluster requests a client certificate"
  fi

  # A certificate is now the whole credential: no authorizer runs behind it,
  # which is what lets a replication stream in. If this ever starts failing
  # with "unauthorized", an authorizer has come back and replication is broken.
  check "$cluster accepts a client certificate with no token" "" \
    cli_public "$cluster" operator namespace list
done

# --- 4. The clusters know about each other -----------------------------------
section "4. Cluster registration"

for viewer in cluster-a cluster-b; do
  listing=$(cli "$viewer" operator cluster list -o json 2>/dev/null)
  for idx in 0 1; do
    name=$(printf '%s' "$listing" | jget "$idx.clusterName")
    addr=$(printf '%s' "$listing" | jget "$idx.address")
    ver=$(printf '%s' "$listing" | jget "$idx.initialFailoverVersion")
    conn=$(printf '%s' "$listing" | jget "$idx.isConnectionEnabled")
    case $name in
      cluster-a) want_ver=1; want_addr=$A_ADDR ;;
      cluster-b) want_ver=2; want_addr=$B_ADDR ;;
      *) fail "$viewer lists a known cluster at index $idx" "got: '${name:-<nothing>}'"; continue ;;
    esac
    if [ "$ver" = "$want_ver" ] && [ "$addr" = "$want_addr" ] && [ "$conn" = "True" -o "$conn" = "true" ]; then
      pass "$viewer sees $name at $addr, failover version $ver, connection enabled"
    else
      fail "$viewer sees $name correctly" \
           "address=$addr (want $want_addr) version=$ver (want $want_ver) connected=$conn"
    fi
  done
done

# Distinct initial failover versions are what let either side resolve a
# conflicting history after a failover. Equal versions would be a silent
# correctness bug rather than an outage, so it is worth asserting.
va=$(cli cluster-a operator cluster list -o json 2>/dev/null | jget 0.initialFailoverVersion)
vb=$(cli cluster-a operator cluster list -o json 2>/dev/null | jget 1.initialFailoverVersion)
if [ -n "$va" ] && [ "$va" != "$vb" ]; then
  pass "the two clusters claim distinct initial failover versions ($va, $vb)"
else
  fail "the two clusters claim distinct initial failover versions" "got '$va' and '$vb'"
fi

# --- 5. Namespace replication -------------------------------------------------
section "5. Namespace replication"

ns_a=$(cli cluster-a operator namespace describe -n "$NAMESPACE" -o json 2>/dev/null)
ns_b=$(cli cluster-b operator namespace describe -n "$NAMESPACE" -o json 2>/dev/null)

id_a=$(printf '%s' "$ns_a" | jget namespaceInfo.id)
id_b=$(printf '%s' "$ns_b" | jget namespaceInfo.id)
ACTIVE=$(printf '%s' "$ns_a" | jget replicationConfig.activeClusterName)

if [ -z "$id_a" ]; then
  fail "namespace '$NAMESPACE' exists on cluster-a" "run ./scripts/connect-clusters.sh first"
else
  pass "namespace '$NAMESPACE' exists on cluster-a"
fi
if [ -z "$id_b" ]; then
  fail "namespace '$NAMESPACE' exists on cluster-b" "it has not replicated across"
else
  pass "namespace '$NAMESPACE' exists on cluster-b"
fi
if [ -n "$id_a" ] && [ "$id_a" = "$id_b" ]; then
  pass "both clusters hold the same namespace, not two namespaces with one name ($id_a)"
elif [ -n "$id_a" ] && [ -n "$id_b" ]; then
  fail "both clusters hold the same namespace" "cluster-a: $id_a, cluster-b: $id_b"
fi

if [ "$(printf '%s' "$ns_a" | jget isGlobalNamespace)" = "True" ]; then
  pass "'$NAMESPACE' is a global namespace"
else
  fail "'$NAMESPACE' is a global namespace" "a local namespace never replicates"
fi

if [ "$ACTIVE" = "$(printf '%s' "$ns_b" | jget replicationConfig.activeClusterName)" ]; then
  pass "both clusters agree the active cluster is '$ACTIVE'"
else
  fail "both clusters agree on the active cluster" \
       "cluster-a says '$ACTIVE', cluster-b says '$(printf '%s' "$ns_b" | jget replicationConfig.activeClusterName)'"
fi

# --- 6. Workflow history replication -----------------------------------------
section "6. Workflow history replication"

if [ -z "$ACTIVE" ]; then
  skip "history replication (could not determine the active cluster)"
else
  case $ACTIVE in
    cluster-a) STANDBY=cluster-b ;;
    *)         STANDBY=cluster-a ;;
  esac

  WF_ID="xdc-verify-$$-$(date +%s)"
  note "starting a workflow on the active cluster ($ACTIVE) and watching $STANDBY"

  started=$(cli "$ACTIVE" workflow start \
    -n "$NAMESPACE" --task-queue xdc-verify --type XdcVerifyProbe \
    --workflow-id "$WF_ID" -o json 2>&1)
  run_id=$(printf '%s' "$started" | jget runId)

  if [ -z "$run_id" ]; then
    fail "started a probe workflow on $ACTIVE" "$(printf '%s' "$started" | tail -1)"
  else
    pass "started a probe workflow on $ACTIVE (run $run_id)"

    # No worker is listening, which is fine: the WorkflowExecutionStarted event
    # is written and replicated regardless of whether anything picks the task up.
    found_run=""
    elapsed=0
    while [ "$elapsed" -lt 60 ]; do
      found_run=$(cli "$STANDBY" workflow describe -n "$NAMESPACE" -w "$WF_ID" -o json 2>/dev/null \
                    | jget workflowExecutionInfo.execution.runId)
      [ -n "$found_run" ] && break
      sleep 2
      elapsed=$((elapsed + 2))
    done

    if [ -z "$found_run" ]; then
      fail "the execution replicated to $STANDBY" "not visible after 60s"
    elif [ "$found_run" != "$run_id" ]; then
      fail "the execution replicated to $STANDBY" "run id differs: $found_run vs $run_id"
    else
      pass "the execution replicated to $STANDBY in ~${elapsed}s, same run id"
    fi

    if [ "$KEEP_PROBE" = false ]; then
      cli "$ACTIVE" workflow terminate -n "$NAMESPACE" -w "$WF_ID" \
        --reason "verify-replication.sh cleanup" >/dev/null 2>&1 \
        && note "terminated the probe workflow" \
        || note "could not terminate the probe workflow $WF_ID - clean it up by hand"
    else
      note "left the probe workflow $WF_ID running (--keep)"
    fi
  fi
fi

# --- 7. Failover --------------------------------------------------------------
section "7. Failover"

if [ "$DO_FAILOVER" = false ]; then
  skip "failover (pass --failover to include it; it flips the namespace and flips it back)"
elif [ -z "$ACTIVE" ]; then
  skip "failover (could not determine the active cluster)"
else
  case $ACTIVE in
    cluster-a) TARGET=cluster-b ;;
    *)         TARGET=cluster-a ;;
  esac

  before=$(cli "$ACTIVE" operator namespace describe -n "$NAMESPACE" -o json 2>/dev/null | jget failoverVersion)

  if cli "$TARGET" operator namespace update -n "$NAMESPACE" --active-cluster "$TARGET" >/dev/null 2>&1; then
    pass "failed '$NAMESPACE' over to $TARGET"
    sleep 5

    # The interesting half is the *old* active cluster learning about it, which
    # only happens if replication is flowing in that direction too.
    seen_by_old=$(cli "$ACTIVE" operator namespace describe -n "$NAMESPACE" -o json 2>/dev/null \
                    | jget replicationConfig.activeClusterName)
    after=$(cli "$TARGET" operator namespace describe -n "$NAMESPACE" -o json 2>/dev/null | jget failoverVersion)

    if [ "$seen_by_old" = "$TARGET" ]; then
      pass "$ACTIVE learned about the failover (replication flows both ways)"
    else
      fail "$ACTIVE learned about the failover" "it still reports '$seen_by_old'"
    fi

    if [ -n "$after" ] && [ "$after" != "$before" ]; then
      pass "failover version advanced ($before -> $after)"
    else
      fail "failover version advanced" "still '$after'"
    fi

    if cli "$ACTIVE" operator namespace update -n "$NAMESPACE" --active-cluster "$ACTIVE" >/dev/null 2>&1; then
      pass "failed back to $ACTIVE"
    else
      fail "failed back to $ACTIVE" "the namespace is left active on $TARGET"
    fi
  else
    fail "failed '$NAMESPACE' over to $TARGET"
  fi
fi

# --- summary ------------------------------------------------------------------
printf '\n%s== Summary ==%s\n' "$BOLD" "$RESET"
printf '  %s%d passed%s' "$GREEN" "$PASSED" "$RESET"
[ "$FAILED" -gt 0 ]  && printf ', %s%d failed%s' "$RED" "$FAILED" "$RESET"
[ "$SKIPPED" -gt 0 ] && printf ', %s%d skipped%s' "$YELLOW" "$SKIPPED" "$RESET"
printf '\n\n'

[ "$FAILED" -eq 0 ]
