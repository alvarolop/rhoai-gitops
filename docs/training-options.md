# Training and predictive ML in RHOAI 3.5

RHOAI has several ways to "train", and they are not interchangeable. This is how they fit and what the chart sets up.

## 1. Which one for what

| I want to... | Use |
|---|---|
| Explore or try something quickly | Workbench (notebook) |
| A repeatable flow (data → train → evaluate → register) | AI Pipeline |
| Predictive model without writing the flow (CSV → best model) | AutoML (Technology Preview) |
| Train or fine-tune a PyTorch model, on one or several nodes | `TrainJob` (Kubeflow Trainer v2) |
| Generic distributed Python (hyperparameter tuning, big data) | Ray (`RayJob` / `RayCluster`) |
| Serve a model | KServe / llm-d |

Plan for this repo: **fine-tuning of a small model on GPU with `TrainJob`**, and **predictive ML on CPU with AutoML or a small pipeline**. Ray is not needed for either.

## 2. Kubeflow Trainer v2 (`TrainJob`)

- `TrainJob` is the only resource a user creates. The administrator defines `ClusterTrainingRuntime` (cluster) or `TrainingRuntime` (namespace): image, how the pods are laid out, framework. A job points to one with `runtimeRef`. The operator creates the `ClusterTrainingRuntime`s when `trainer` is `Managed`.
- A `TrainJob` does not create pods itself: it creates a `JobSet` (a group of Jobs managed as one unit), and the **JobSet operator** runs it. The chain is `TrainJob` → `JobSet` → `Job`s → pods. The operator is mandatory: the `Trainer` component stays `PreConditionFailed` ("JobSetOperator CR with name 'cluster' not found") until a `JobSetOperator` named `cluster` exists. The subscription and that CR are in `rhoai-dependencies/operator-jobset`.
- Runtimes that exist once `trainer` is `Managed`: `torch-distributed-cpu` and `torch-distributed-cpu-torch211-py312` (CPU), `torch-distributed-cuda130-torch211-py312` (NVIDIA GPU), `training-hub` and `training-hub-cpu` (fine-tuning), plus ROCm variants (AMD, not used here). List them with `oc get clustertrainingruntime`.
- PyTorch coordinates the nodes itself (`torchrun`). There is no Ray inside a `TrainJob`.
- Kubeflow Training Operator v1 (`PyTorchJob`, `TFJob`, `MPIJob`...) is deprecated since RHOAI 2.25 and replaced by Trainer v2. This chart keeps `trainingoperator` `Removed`.
- Open check: Trainer v2 with Kueue 1.5 on RHOAI 3.5.3 is untested here. In 3.4 the integration was broken with Red Hat build of Kueue 1.4 or later (RHOAIENG-87965), and 3.6 requires it. If a `TrainJob` is not admitted by Kueue, look there first.

## 3. Ray

- `ray` is `Managed` in the DataScienceCluster: the `kuberay-operator` runs in `redhat-ods-applications` and the `RayCluster`, `RayJob` and `RayService` CRDs exist. Ray replaces CodeFlare.
- Ray is its own stack: a `RayCluster` is a head pod plus worker pods, and Ray schedules and parallelizes inside it. A `RayJob` creates a cluster, runs a script and deletes it. The operator only creates and deletes the pods.
- The Kueue CR that RHOAI creates already lists `RayCluster` and `RayJob`, so they are admitted through the same queues as `TrainJob`.
- It pays off when the work no longer fits in one process: Tune (many trainings in parallel), Ray Data (big data), Ray Train. For scikit-learn, try `n_jobs=-1` first, then the joblib Ray backend, which parallelizes the same code with very few changes.

## 4. Pipelines and AutoML

- **AI Pipeline:** steps are containers with inputs and outputs. If a step later needs Ray, only that step changes (it creates a `RayJob` or connects to a `RayCluster` and waits); the rest of the pipeline stays.
- **AutoML (Technology Preview in 3.5):** a ready-made pipeline. You give it a CSV in S3 (up to 32 MiB from the dashboard, 100 MB from S3) and a task (binary or multiclass classification, regression, time series). It trains candidates, shows a leaderboard with ROC and precision-recall curves, and registers the best model in the Model Registry. AutoGluon is available as a serving runtime (Technology Preview).
- AutoML cannot be edited: no algorithm choice, no hyperparameters, no Ray. If more control is needed, drop AutoML and write your own pipeline; the two cannot be mixed. The registered model of an AutoML run can be the input of your own pipeline.
- Needs a pipeline server in the project with "Enable AutoML and AutoRAG pipelines" (`managedPipelines: {}` in the `DataSciencePipelinesApplication`), and `dashboardConfig.automl: true` (already in `OdhDashboardConfig.yaml`).
- Known issue RHOAIENG-64768: AutoML and AutoRAG runs can fail with image pull errors; the release notes ask to upload updated pipeline definitions before the first run.

## 5. What the chart sets up

`training.enabled` in `values.yaml` (default `true`):

- `trainer` `Managed` in the `DataScienceCluster` (`trainingoperator` is always `Removed`).
- The `rhoai-training` project (`templates/14-training`): a dashboard project and a Kueue namespace (`kueue.openshift.io/managed=true`).
- Its LocalQueues `default`, `serving-lq` and `batch-lq`, from `distributedWorkloads.localQueueNamespaces`. If you turn training off, remove `rhoai-training` from that list or the sync fails.

Which queue to use:

| Work | Queue | Behind it |
|---|---|---|
| Notebooks, CPU training, classical ML | `default` | `default-cq` (CPU, not preemptive, as workbenches require) |
| GPU fine-tuning | `batch-lq` | `batch-cq`: borrows idle GPU from the pool; with the quota of `serving-cq` raised to 100 GPUs it is not evicted when a model arrives (see the note in `ClusterQueue-serving.yaml`) |

The chart does not create jobs, a pipeline server or buckets; those are created when the demo is run.

## 6. Changing queues on a cluster that already runs

Some fields cannot be changed in place, so a sync fails with "field is immutable":

- `LocalQueue.spec.clusterQueue`: after the rename `cluster-queue` → `default-cq`, delete the old `default` LocalQueue of each namespace and sync again. Workloads already admitted stay in the old ClusterQueue until their pods restart; with `prune: false` the old `cluster-queue` is not deleted automatically.
- `ResourceClaimTemplate.spec` (the GPU t-shirt sizes): delete the template and sync again. Safe while no `ResourceClaim` uses it.

A namespace outside this chart that is not meant for GPU work (for example the playground) can simply leave Kueue: drop the label `kueue.openshift.io/managed` and its LocalQueue. Pods already admitted keep running; restart them so they stop going through Kueue.

## 7. Pending

- GPU fine-tuning needs a GPU node (none in the cluster now). `batch-cq` borrows at most 1 GPU (`borrowingLimit`).
- Check Trainer v2 admission by Kueue with the first `TrainJob`.
- Decide where the pipeline server and the S3 bucket for AutoML live.
