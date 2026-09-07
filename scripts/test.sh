#!/bin/sh

echo "Testing cluster A"
temporal operator cluster health \
  --address localhost:7233 \
  --tls-cert-path ./certs/cluster-a/client.pem \
  --tls-key-path ./certs/cluster-a/client.key \
  --tls-ca-path ./certs/ca/ca.pem

echo "Testing cluster B"
temporal operator cluster health \
  --address localhost:8233 \
  --tls-cert-path ./certs/cluster-b/client.pem \
  --tls-key-path ./certs/cluster-b/client.key \
  --tls-ca-path ./certs/ca/ca.pem

# sanity-check the raw TLS handshake for cluster A
echo "Sanity-checking cluster A"
openssl s_client -connect localhost:7233 \
  -cert ./certs/cluster-a/client.pem \
  -key ./certs/cluster-a/client.key \
  -CAfile ./certs/ca/ca.pem

# sanity-check the raw TLS handshake for cluster B  
echo "Sanity-checking cluster B"
openssl s_client -connect localhost:8233 \
  -cert ./certs/cluster-b/client.pem \
  -key ./certs/cluster-b/client.key \
  -CAfile ./certs/ca/ca.pem

# The client secret lives in .env (written there by scripts/setup-keycloak.sh),
# never in this file.
[ -f .env ] && . ./.env
: "${KEYCLOAK_CLIENT_SECRET:?KEYCLOAK_CLIENT_SECRET is not set - run scripts/setup-keycloak.sh or set it in .env}"

export TEMPORAL_GRPC_META_AUTHORIZATION="Bearer $(curl -X POST http://localhost:9080/realms/temporal/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=temporal-app" \
  -d "client_secret=$KEYCLOAK_CLIENT_SECRET" | jq -r '.access_token')"

  # verify the clusters are connected
temporal operator cluster list --address localhost:7233 \
  --tls-cert-path ./certs/cluster-a/client.pem \
  --tls-key-path ./certs/cluster-a/client.key \
  --tls-ca-path ./certs/ca/ca.pem

# verify the clusters are connected
temporal operator cluster list --address localhost:8233 \
  --tls-cert-path ./certs/cluster-b/client.pem \
  --tls-key-path ./certs/cluster-b/client.key \
  --tls-ca-path ./certs/ca/ca.pem

