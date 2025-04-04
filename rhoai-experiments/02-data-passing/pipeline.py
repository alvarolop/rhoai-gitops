from kfp import dsl
from kfp import compiler
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
    # Instantiate the compiler
    pipeline_compiler = compiler.Compiler()

    # Get current script directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    yaml_path = os.path.join(script_dir, "pipeline.yaml")
    
    # Compile the pipeline to IR YAML
    pipeline_compiler.compile(
        pipeline_func=pipeline,
        package_path=yaml_path
    )
    print(f"Pipeline YAML generated at: {yaml_path}")
