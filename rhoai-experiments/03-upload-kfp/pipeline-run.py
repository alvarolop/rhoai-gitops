from kfp import dsl
from kfp.client import Client
import os

@dsl.component
def create_hello_message(name: str) -> str:
    """Creates a hello message."""
    hello_text = f'Hello, {name}!'
    return hello_text

@dsl.component
def say_hello(message: str):
    """Prints the hello message."""
    print(message)

@dsl.pipeline(name="hello-world-pipeline")
def pipeline(recipient: str):
    # Step 1: Create the hello message
    hello_message = create_hello_message(name=recipient)
    
    # Step 2: Pass the generated message to say_hello for printing
    say_hello(message=hello_message.output)

if __name__ == "__main__":
    # SVC: https://ds-pipeline-dspa.{namespace}.svc:8443
    # Route: https://ds-pipeline-dspa-rhoai-playground.apps.$CLUSTER_DOMAIN
    kubeflow_endpoint = os.environ["KUBEFLOW_ENDPOINT"]
    bearer_token = os.environ["BEARER_TOKEN"]

    print(f'Connecting to Data Science Pipelines: {kubeflow_endpoint}')
    client = Client(
        host=kubeflow_endpoint,
        existing_token=bearer_token
    )
    result = client.create_run_from_pipeline_func(
        pipeline,
        arguments={"recipient": "Exercise 3A!"},
        experiment_name='automated-pipeline-run',
    )
    print(f'Starting pipeline run with run_id: {result.run_id}')
