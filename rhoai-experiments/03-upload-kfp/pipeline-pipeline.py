from kfp import dsl
from kfp import compiler
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

    # 1. Create KFP client
    print(f'Connecting to Data Science Pipelines: {kubeflow_endpoint}')
    client = Client(
        host=kubeflow_endpoint,
        existing_token=bearer_token
    )

    # 2. Create pipeline object
    pipeline_package = compiler.Compiler().compile(
        pipeline_func=pipeline,
        package_path="hello_world_pipeline.yaml"
    )

    # 3. Upload pipeline to KFP registry
    pipeline_obj = client.upload_pipeline(
        pipeline_package_path="hello_world_pipeline.yaml",
        pipeline_name="hello-world-pipeline"
    )

    # 4. Create experiment (organizational container)
    experiment = client.create_experiment(
        name="hello-world-experiment",
        description="Runs our greeting pipeline"
    )

    # 5. Execute pipeline run
    run_result = client.run_pipeline(
        experiment_id=experiment.experiment_id,
        job_name="hello-world-execution",
        pipeline_id=pipeline_obj.pipeline_id,
        params={"recipient": "Exercise 3B!"}
    )
