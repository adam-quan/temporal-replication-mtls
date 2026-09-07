import asyncio
from temporalio.client import Client
from temporalio.worker import Worker
from temporalio import workflow

from simple_workflow import say_hello_activity, SimpleWorkflow
import token_utility
import tls_utility

async def main():
    # 1. Fetch initial token data to establish the connection
    print("Fetching initial token from Keycloak...")
    initial_token_data = await token_utility.fetch_keycloak_token_info()
    initial_jwt = initial_token_data["access_token"]

    # 2. Instantiate the Temporal client
    client = await Client.connect(
        tls_utility.TEMPORAL_ADDRESS,
        namespace=tls_utility.TEMPORAL_NAMESPACE,
        tls=tls_utility.tls_config(),
        rpc_metadata={"authorization": f"Bearer {initial_jwt}"}
    )

    # 3. Spin up the background tracking loop for JWT rotation
    refresh_task = asyncio.create_task(token_utility.token_refresh_loop(client))

    # 4. Bind and execute the Temporal Worker
    worker = Worker(
        client,
        task_queue="hello-task-queue",
        workflows=[SimpleWorkflow],
        activities=[say_hello_activity]
    )
    
    try:
        print("Temporal Worker is online and listening...")
        await worker.run()
    finally:
        refresh_task.cancel()

if __name__ == "__main__":
    asyncio.run(main())

