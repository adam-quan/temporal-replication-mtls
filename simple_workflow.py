import asyncio
from datetime import timedelta
from temporalio import activity, workflow
from temporalio.client import Client
import token_utility
import tls_utility

# 1. Define the Activity (Your business logic)
@activity.defn
async def say_hello_activity(name: str) -> str:
    return f"Hello, {name}!"

# 2. Define the Workflow (Orchestration logic)
@workflow.defn
class SimpleWorkflow:
    @workflow.run
    async def run(self, name: str) -> str:
        # Executes the activity with a mandatory timeout constraint
        return await workflow.execute_activity(
            say_hello_activity,
            name,
            start_to_close_timeout=timedelta(seconds=5),
        )

# 3. Main runner to spin up a worker and execute the workflow
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

    # 3. Execute the workflow synchronously and print the result
    result = await client.execute_workflow(
        SimpleWorkflow.run,
        "World",
        id="hello-workflow-id",
        task_queue="hello-task-queue",
    )
    
    print(f"Workflow Result: {result}")

if __name__ == "__main__":
    asyncio.run(main())

