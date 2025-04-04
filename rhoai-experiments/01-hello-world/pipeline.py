from kfp import dsl
from kfp import compiler
import os

@dsl.component
def say_hello(name: str) -> str:
    hello_text = f'Hello, {name}!'
    print(hello_text)
    return hello_text

@dsl.pipeline(name="hello-world-pipeline")
def pipeline(recipient: str) -> str:
    hello_task = say_hello(name=recipient)
    return hello_task.output

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
