import os
from pathlib import Path

from temporalio.service import TLSConfig

# Both cluster frontends run with requireClientAuth, so an SDK client needs a
# certificate of its own on top of the JWT. Point these at cluster-b's copies
# (or export the variables) to run the samples against the second cluster:
#
#   TEMPORAL_ADDRESS=localhost:8233 \
#   TEMPORAL_TLS_CLUSTER=cluster-b \
#   TEMPORAL_TLS_SERVER_NAME=temporal-b \
#   python3 worker.py

CERTS_DIR = Path(os.environ.get("CERTS_DIR", Path(__file__).parent / "certs"))
CLUSTER = os.environ.get("TEMPORAL_TLS_CLUSTER", "cluster-a")

TEMPORAL_ADDRESS = os.environ.get("TEMPORAL_ADDRESS", "localhost:7233")
TEMPORAL_NAMESPACE = os.environ.get("TEMPORAL_NAMESPACE", "default")

# The frontend certificate is issued for the container name, not for
# "localhost", so tell the SDK which name to verify against. It also lists
# localhost as a SAN, so dropping this would work too - being explicit keeps
# the sample honest about what is being checked.
SERVER_NAME = os.environ.get("TEMPORAL_TLS_SERVER_NAME", "temporal")


def tls_config() -> TLSConfig:
    """Client certificate and trust root for the mTLS frontend."""
    cluster_dir = CERTS_DIR / CLUSTER
    ca = CERTS_DIR / "ca" / "ca.pem"

    missing = [p for p in (ca, cluster_dir / "client.pem", cluster_dir / "client.key") if not p.exists()]
    if missing:
        raise FileNotFoundError(
            "Missing certificate(s): "
            + ", ".join(str(p) for p in missing)
            + ". Run ./scripts/generate-certs.sh first."
        )

    return TLSConfig(
        server_root_ca_cert=ca.read_bytes(),
        client_cert=(cluster_dir / "client.pem").read_bytes(),
        client_private_key=(cluster_dir / "client.key").read_bytes(),
        domain=SERVER_NAME,
    )
