import asyncio
from datetime import timedelta
from temporalio import activity, workflow
from temporalio.client import Client
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
    # 1. Instantiate the Temporal client. The frontend authenticates callers
    #    by client certificate, so the certificate is the whole credential.
    client = await Client.connect(
        tls_utility.TEMPORAL_ADDRESS,
        namespace=tls_utility.TEMPORAL_NAMESPACE,
        tls=tls_utility.tls_config(),
    )

    # 2. Execute the workflow synchronously and print the result
    result = await client.execute_workflow(
        SimpleWorkflow.run,
        "World",
        id="hello-workflow-id",
        task_queue="hello-task-queue",
    )
    
    print(f"Workflow Result: {result}")

if __name__ == "__main__":
    asyncio.run(main())

