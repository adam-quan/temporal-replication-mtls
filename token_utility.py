import asyncio
import os

from dotenv import load_dotenv
from temporalio.client import Client
from temporalio import workflow

# Wrap non-deterministic imports inside this context manager
with workflow.unsafe.imports_passed_through():
    from keycloak import KeycloakOpenID

load_dotenv()

# 1. Configure your Keycloak client properties
KEYCLOAK_URL = "http://localhost:9080/"  # Or your Keycloak base URL
REALM_NAME = "temporal"
CLIENT_ID = "temporal-app"
CLIENT_SECRET = os.environ["KEYCLOAK_CLIENT_SECRET"]

# Initialize Keycloak OpenID client
keycloak_openid = KeycloakOpenID(
    server_url=KEYCLOAK_URL,
    realm_name=REALM_NAME,
    client_id=CLIENT_ID,
    client_secret_key=CLIENT_SECRET
)

async def fetch_keycloak_token_info() -> dict:
    """
    Executes a synchronous call in an executor block to fetch 
    the Client Credentials token from Keycloak.
    """
    loop = asyncio.get_running_loop()
    # python-keycloak token() executes blocking I/O, run it in a thread pool.
    # Use the client credentials grant: this is a service-to-service call, so it
    # authenticates as the client's service account rather than as an end user.
    # The password grant would open a new Keycloak SSO session on every refresh,
    # leaking sessions for as long as ssoSessionMaxLifespan.
    token_response = await loop.run_in_executor(
        None,
        lambda: keycloak_openid.token(grant_type="client_credentials")
    )
    return token_response

async def token_refresh_loop(client: Client):
    """
    Background worker loop that manages dynamic JWT rotation.
    Reads token lifetime returned by Keycloak and refreshes proactively.
    """
    while True:
        try:
            token_data = await fetch_keycloak_token_info()
            jwt_token = token_data["access_token"]
            
            # Mutate the client rpc metadata seamlessly
            client.rpc_metadata = {"authorization": f"Bearer {jwt_token}"}
            print("Successfully refreshed JWT from Keycloak.")
            
            # Use Keycloak's 'expires_in' field to determine sleep cycle
            # Buffer by 30 seconds to ensure the token doesn't expire mid-flight
            expires_in = token_data.get("expires_in", 300)
            sleep_duration = max(10, expires_in - 30) 
            
        except Exception as e:
            print(f"Failed to fetch token from Keycloak: {e}")
            # If Keycloak is transiently down, try again shortly
            sleep_duration = 15 
            
        await asyncio.sleep(sleep_duration)