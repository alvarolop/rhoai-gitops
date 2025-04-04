# Red Hat OpenShift AI Experiments with Kubeflow Pipelines


Welcome to the `rhoai-experiments` repository! This repository contains hands-on experiments designed to help you learn and master Kubeflow Pipelines in Red Hat OpenShift AI. Each experiment builds on the previous one, gradually increasing complexity and introducing new concepts.

> [!IMPORTANT]
> This section requires a DataSciencePipelinesApplication (DSPA) resource up and running in the namespace where you want to runt he pipelines. If you don't have one, use the namespace `rhoai-playground` which is created in the installation script.

## How Experiments Work

Experiments in this repository are structured as individual folders, each containing:
- A `pipeline.py` file: The Python code for the Kubeflow Pipeline.
<!-- - A `README.adoc` file: Detailed instructions for setting up, running, and understanding the experiment. -->

Each experiment demonstrates a specific concept or use case in Kubeflow Pipelines, such as:
- Data passing between components
- Model training
- Hyperparameter tuning
- Model registry integration

## Experiment Index

Below is a table summarizing each experiment in this repository:

| **Experiment**                       | **Description**                                                 | **Key Concepts Covered**                                |
|--------------------------------------|-----------------------------------------------------------------|--------------------------------------------------------|
| Ex 01: Hello World              | A simple pipeline that prints "Hello OpenShift AI!" to demonstrate basic setup. | Pipeline creation, compiling pipelines, uploading pipelines. |
| Ex 02: Data Passing Between Components | A pipeline with two components that pass data between them.      | Component dependencies, input/output handling.        |
| Ex 03A: Create Run in RHOAI | A pipeline that automatically executes itself as a Run in RHOAI.          | Component dependencies, upload.        
| Ex 03B: Create Pipeline in RHOAI | A pipeline that automatically creates itself in RHOAI.          | Component dependencies, upload.                 |
| Ex 03: Model Training           | A pipeline that preprocesses data and trains a machine learning model. | Data preparation, model training, persistent volumes. |
| Ex 04: Conditional Execution    | A workflow that branches based on data quality checks.          | Conditional logic, validation gates.                  |
| Ex 05: Hyperparameter Tuning    | A pipeline that performs hyperparameter tuning using `Katib`.   | Search spaces, optimization algorithms, AutoML.       |
| Ex 06: Model Registry Integration | A pipeline that registers trained models in the Model Registry.  | Model registration, metadata management, model versioning. |
| Ex 07: Docling Ingestion        | Converts PDF documents to structured Markdown.                  | File processing, text extraction, format conversion.   |
---

## Running pipelines

### Ex 01: Hello World

```bash
python rhoai-experiments/01-hello-world/pipeline.py
```

### Ex 02: Data Passing between components

```bash
python rhoai-experiments/02-data-passing/pipeline.py
```

### Ex 03A: Create a Pipeline Run

```bash
export KUBEFLOW_ENDPOINT=$(oc get route ds-pipeline-dspa -n rhoai-playground --template="https://{{.spec.host}}")
export BEARER_TOKEN=$(oc whoami --show-token)
python rhoai-experiments/03-upload-kfp/pipeline-run.py
```

### Ex 03B: Upload a Pipeline 

```bash
export KUBEFLOW_ENDPOINT=$(oc get route ds-pipeline-dspa -n rhoai-playground --template="https://{{.spec.host}}")
export BEARER_TOKEN=$(oc whoami --show-token)
python rhoai-experiments/03-upload-kfp/pipeline-run.py
```




## Useful links for Pipelines

* [Jukebox example from rhoai-mlops](https://github.com/rhoai-mlops/jukebox/tree/main/3-prod_datascience).
* [Max os-mlops example on Pipelines Triggers](https://github.com/mamurak/os-mlops/blob/main/manifests/ml-pipelines-pattern/templates/tekton/kfp-pipeline-ci.yaml#L195-L263).
* [RH AI BU - Kubeflow pipelines examples](https://github.com/redhat-ai-services/kubeflow-pipelines-examples/tree/main/pipelines).
* [Platform Foundation Bootcamp - RHOAI](https://redhat-ai-services.github.io/rhoai-platform-foundation-bootcamp-instructions/modules/42_working_with_pipelines.html#_create_a_pipeline_to_train_a_model).
* [RH AI BU - AI-accelerator](https://github.com/redhat-ai-services/ai-accelerator/tree/main/tenants/ai-example/dsp-example-pipeline).
