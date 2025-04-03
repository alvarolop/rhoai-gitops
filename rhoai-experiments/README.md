# Red Hat OpenShift AI Experiments with Kubeflow Pipelines

Welcome to the `rhoai-experiments` repository! This repository contains hands-on experiments designed to help you learn and master Kubeflow Pipelines in Red Hat OpenShift AI. Each experiment builds on the previous one, gradually increasing complexity and introducing new concepts.

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
| Exercise 1: Hello World              | A simple pipeline that prints "Hello OpenShift AI!" to demonstrate basic setup. | Pipeline creation, compiling pipelines, uploading pipelines. |
| Exercise 2: Automatic Upload to RHOAI | A pipeline that automatically uploads itself to RHOAI.          | Component dependencies, upload.                       |
| Exercise 2: Data Passing Between Components | A pipeline with two components that pass data between them.      | Component dependencies, input/output handling.        |
| Exercise 3: Model Training           | A pipeline that preprocesses data and trains a machine learning model. | Data preparation, model training, persistent volumes. |
| Exercise 4: Conditional Execution    | A workflow that branches based on data quality checks.          | Conditional logic, validation gates.                  |
| Exercise 5: Hyperparameter Tuning    | A pipeline that performs hyperparameter tuning using `Katib`.   | Search spaces, optimization algorithms, AutoML.       |
| Exercise 6: Model Registry Integration | A pipeline that registers trained models in the Model Registry.  | Model registration, metadata management, model versioning. |
| Exercise 7: Docling Ingestion        | Converts PDF documents to structured Markdown.                  | File processing, text extraction, format conversion.   |

---