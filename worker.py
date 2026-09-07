import asyncio
from temporalio.client import Client
from temporalio.worker import Worker
from temporalio import workflow

from simple_workflow import say_hello_activity, SimpleWorkflow
import tls_utility

async def main():
    # 1. Instantiate the Temporal client. The frontend authenticates callers
    #    by client certificate, so the certificate is the whole credential.
    client = await Client.connect(
        tls_utility.TEMPORAL_ADDRESS,
        namespace=tls_utility.TEMPORAL_NAMESPACE,
        tls=tls_utility.tls_config(),
    )

    # 2. Bind and execute the Temporal Worker
    worker = Worker(
        client,
        task_queue="hello-task-queue",
        workflows=[SimpleWorkflow],
        activities=[say_hello_activity]
    )
    
    print("Temporal Worker is online and listening...")
    await worker.run()

if __name__ == "__main__":
    asyncio.run(main())

