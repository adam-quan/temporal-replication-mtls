#!/usr/bin/env bash
#
# Generates the self-signed PKI used for mTLS between (and inside) the two
# Temporal clusters.
#
#   certs/ca/ca.pem                  root CA, trusted by both clusters
#   certs/<cluster>/internode.pem    internode + internal-frontend identity.
#                                    Carries serverAuth AND clientAuth, because
#                                    it is both the certificate the internal
#                                    frontend presents to the peer cluster and
#                                    the client certificate this cluster
#                                    presents when dialing the peer.
#   certs/<cluster>/frontend.pem     public frontend identity (serverAuth)
#   certs/<cluster>/client.pem       identity for external callers - the Web UI,
#                                    the CLI, and the Python SDK samples
#
# One CA signs both clusters. That is the smallest thing that still gives real
# mutual authentication; for separate per-cluster CAs, run this script twice
# with different CA_DIR values and list both CA files under `clientCaFiles` and
# `rootCaFiles` in each cluster's config.yaml.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CERTS_DIR=${CERTS_DIR:-$ROOT_DIR/certs}
CA_DIR=$CERTS_DIR/ca
DAYS=${CERT_DAYS:-3650}
KEY_BITS=${CERT_KEY_BITS:-2048}

# Hostnames each cluster is reachable at. The internode certificate's *first*
# SAN doubles as the TLS server name the peer verifies, so it must match the
# `serverName` fields in the corresponding config.yaml.
A_INTERNAL_NAME=${CLUSTER_A_INTERNAL_NAME:-temporal-a.internal}
B_INTERNAL_NAME=${CLUSTER_B_INTERNAL_NAME:-temporal-b.internal}
A_HOST=${CLUSTER_A_HOST:-temporal}
B_HOST=${CLUSTER_B_HOST:-temporal-b}

mkdir -p "$CA_DIR"

# create_ca - self-signed root, reused on re-runs so existing leaf certs stay valid.
create_ca() {
  if [ -f "$CA_DIR/ca.pem" ] && [ -f "$CA_DIR/ca.key" ]; then
    echo "CA already exists at $CA_DIR/ca.pem, reusing it"
    return
  fi
  echo "Generating root CA..."
  openssl req -x509 -newkey "rsa:$KEY_BITS" -nodes \
    -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.pem" -days "$DAYS" \
    -subj "/O=Temporal XDC Lab/CN=Temporal XDC Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}

# issue <out_dir> <name> <common_name> <ext_key_usage> <san_list>
issue() {
  out_dir=$1; name=$2; cn=$3; eku=$4; sans=$5
  mkdir -p "$out_dir"
  echo "  issuing $name.pem (CN=$cn)"

  ext_file=$(mktemp)
  cat > "$ext_file" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=$eku
subjectAltName=$sans
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EXT

  openssl req -newkey "rsa:$KEY_BITS" -nodes \
    -keyout "$out_dir/$name.key" -out "$out_dir/$name.csr" \
    -subj "/O=Temporal XDC Lab/CN=$cn" 2>/dev/null

  openssl x509 -req -in "$out_dir/$name.csr" \
    -CA "$CA_DIR/ca.pem" -CAkey "$CA_DIR/ca.key" -CAcreateserial \
    -out "$out_dir/$name.pem" -days "$DAYS" -extfile "$ext_file" 2>/dev/null

  rm -f "$out_dir/$name.csr" "$ext_file"
}

# issue_cluster <dir_name> <internal_name> <container_host>
issue_cluster() {
  dir=$CERTS_DIR/$1; internal_name=$2; host=$3
  echo "Generating certificates for $1..."

  # Both ends of the cross-cluster connection use this one, hence both EKUs.
  issue "$dir" internode "$internal_name" "serverAuth,clientAuth" \
    "DNS:$internal_name,DNS:$host,DNS:localhost,IP:127.0.0.1"

  # Presented to external clients on the public frontend port.
  issue "$dir" frontend "$host" "serverAuth" \
    "DNS:$host,DNS:$internal_name,DNS:localhost,IP:127.0.0.1"

  # Presented *by* external clients, since the frontend requires client auth.
  issue "$dir" client "$1-client" "clientAuth" "DNS:$1-client"
}

create_ca
issue_cluster cluster-a "$A_INTERNAL_NAME" "$A_HOST"
issue_cluster cluster-b "$B_INTERNAL_NAME" "$B_HOST"

# The server runs as uid 1000 inside the container and reads these through a
# read-only bind mount, so the private keys have to be world readable. Fine for
# a local lab, never do this with certificates that protect anything.
chmod 644 "$CA_DIR"/*.key "$CERTS_DIR"/cluster-*/*.key

echo
echo "Done. Certificates written to $CERTS_DIR"
openssl x509 -in "$CA_DIR/ca.pem" -noout -subject -dates
