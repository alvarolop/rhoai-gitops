#!/bin/bash

set -e

#####################################
# Set your environment variables here
#####################################

CREATE_GPU_MACHINESETS=true
GPU_NODE_COUNT=0  # Total GPU nodes to distribute across AZs (a, b, c)
INSTALL_MINIO=true
INSTALL_ODF=false
INSTALL_MONITORING=true
INSTALL_LANGFUSE=true
INSTALL_PIPELINES=true
CREATE_RHOAI_ENV=true
AWS_GPU_INSTANCE=g5.4xlarge

# Define the required memory
REQUIRED_MEMORY_Gi="70"

#####################################
## Do not modify anything from this line
#####################################

# Print feature toggles and GPU config
echo -e "\n===================="
echo -e "FEATURE TOGGLES & CONFIG:"
echo -e " * CREATE_GPU_MACHINESETS: $CREATE_GPU_MACHINESETS"
echo -e " * GPU_NODE_COUNT: $GPU_NODE_COUNT"
echo -e " * AWS_GPU_INSTANCE: $AWS_GPU_INSTANCE"
echo -e " * INSTALL_MINIO: $INSTALL_MINIO"
echo -e " * INSTALL_ODF: $INSTALL_ODF"
echo -e " * INSTALL_MONITORING: $INSTALL_MONITORING"
echo -e " * INSTALL_PIPELINES: $INSTALL_PIPELINES"
echo -e " * INSTALL_LANGFUSE: $INSTALL_LANGFUSE"
echo -e " * CREATE_RHOAI_ENV: $CREATE_RHOAI_ENV"
echo -e " * REQUIRED_MEMORY_Gi: $REQUIRED_MEMORY_Gi"
echo -e "====================\n"

# Check if the user is logged in 
if ! oc whoami &> /dev/null; then
    echo -e "❌ Check. You are not logged out. Please log in and run the script again."
    exit 1
else
    echo -e "✅ Check. You are correctly logged in. Continue..."
    if ! oc project &> /dev/null; then
        echo -e "📂 Current project does not exist, moving to project Default."
        oc project default 
    fi
fi


# Get non-tainted nodes
# oc get nodes -o go-template='{{range .items}}{{if not .spec.taints }}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'

AVAILABLE_MEMORY=$(oc get nodes -o go-template='{{range .items}}{{if not .spec.taints }}{{.status.allocatable.memory}}{{"\n"}}{{end}}{{end}}' | sed 's/Ki$//' | paste -sd+ | bc)

# Convert the available memory to Gi
AVAILABLE_MEMORY_Gi=$(echo "scale=2; $AVAILABLE_MEMORY / (1024 * 1024)" | bc)

# Check if there is enough memory
if (( $(echo "$AVAILABLE_MEMORY_Gi < $REQUIRED_MEMORY_Gi" | bc -l) )); then
    echo "⚠️  Not enough memory available in untainted worker nodes. Required: $REQUIRED_MEMORY, Available: $(echo "$AVAILABLE_MEMORY_Gi Gi")"
    read -p "🤔 Proceed? (y/n): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "🚪 Exiting due to insufficient memory."; exit 1; }
    echo "🚀 Proceeding despite insufficient memory..."
else
    echo "💪 Enough memory available. Proceeding with the script..."
    # Rest of your script here
fi

echo -e "\n🖥️ =================="
echo -e "🖥️ =    GPU INFRA   ="
echo -e "🖥️ ==================\n"

if [[ "$CREATE_GPU_MACHINESETS" =~ ^([Tt]rue|[Yy]es|[1])$ ]]; then
    # Distribute GPU_NODE_COUNT across AZs: a gets extra first, then b, then c
    REPLICAS_A=$(( (GPU_NODE_COUNT + 2) / 3 ))
    REPLICAS_B=$(( (GPU_NODE_COUNT + 1) / 3 ))
    REPLICAS_C=$(( GPU_NODE_COUNT / 3 ))

    echo "🎯 Adding $GPU_NODE_COUNT GPU node(s) to the cluster (AZ a: $REPLICAS_A, b: $REPLICAS_B, c: $REPLICAS_C)"

    oc process -f prerequisites/ocp-nodes/template-gpu-worker.yaml \
        -p INFRASTRUCTURE_ID=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster) \
        -p INSTANCE_TYPE="$AWS_GPU_INSTANCE" -p AZ="a" -p REPLICAS=$REPLICAS_A | \
        oc apply -n openshift-machine-api -f -

    oc process -f prerequisites/ocp-nodes/template-gpu-worker.yaml \
        -p INFRASTRUCTURE_ID=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster) \
        -p INSTANCE_TYPE="$AWS_GPU_INSTANCE" -p AZ="b" -p REPLICAS=$REPLICAS_B | \
        oc apply -n openshift-machine-api -f -

    oc process -f prerequisites/ocp-nodes/template-gpu-worker.yaml \
        -p INFRASTRUCTURE_ID=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster) \
        -p INSTANCE_TYPE="$AWS_GPU_INSTANCE" -p AZ="c" -p REPLICAS=$REPLICAS_C | \
        oc apply -n openshift-machine-api -f -

    echo -e "\n⚠️  Remember, those nodes are tainted with 'nvidia.com/gpu:NoSchedule' by default. Modify the template or update the node definition if you want to run normal workloads"
else
    echo "⏭️  Skip creation of NVIDIA gpu nodes..."
fi

if [[ "$INSTALL_ODF" =~ ^([Tt]rue|[Yy]es|[1])$ ]]; then

    # Precheck to ensure there are at least 3 worker nodes without taints for GPU
    echo -e "\n🔍 Precheck: Ensuring there are at least 3 non-GPU worker nodes available..."
    non_gpu_worker_count=$(oc get nodes -l node-role.kubernetes.io/worker --template '{{range .items}}{{if not .spec.taints}}{{.metadata.name}}{{"\n"}}{{else}}{{range .spec.taints}}{{if ne .key "nvidia.com/gpu"}}{{.}}{{end}}{{end}}{{end}}{{end}}' | wc -l)
    if [ "$non_gpu_worker_count" -lt 3 ]; then
        echo "❌ Error: At least 3 non-GPU worker nodes are required. Only $non_gpu_worker_count available."
        echo "📈 Scale up your cluster!"
        exit 1
    else 
        echo "✅ Pass: There are $non_gpu_worker_count non-GPU worker nodes are required available."
    fi
fi

echo -e "\n🛠️ ====================="
echo -e "🛠️ = Install Operators ="
echo -e "🛠️ =====================\n"

echo -e "1️⃣ Trigger the ArgoCD application to install the operators"
oc apply -f application-rhoai-dependencies.yaml


echo -e "\n2️⃣ Wait 20 seconds for Subscriptions to be applied"
for i in {20..1}; do
  echo -ne "\t⏰ Time left: $i seconds.\r"
  sleep 1
done

# Wait for all operators to be in 'Succeeded' state
echo -e "\n3️⃣ Waiting for all operators to be in 'Succeeded' state..."
until [[ -z $(oc get csv --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -v "Succeeded" 2>/dev/null || true) ]]; do
    echo "⏳ Some operators are not in 'Succeeded' state, retrying in 10 seconds..."
    oc get csv --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -v "Succeeded" 2>/dev/null || true
    sleep 10
done
echo -e "\t✅ All operators are in 'Succeeded' state."

# Disabled: https://github.com/rh-ecosystem-edge/console-plugin-nvidia-gpu/issues/71
# echo -e "\t🎮 Enable the NVIDIA GPU Console Plugin to view metrics in the Cluster Overview."
# oc apply -f application-console-plugin-nvidia-gpu.yaml
# echo -e "\t🎮 NVIDIA GPU Console Plugin is deployed."
# # Only patch if the plugin is not already enabled
# if ! oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' | grep -q "console-plugin-nvidia-gpu"; then
#     oc patch consoles.operator.openshift.io cluster --patch '[{"op": "add", "path": "/spec/plugins/-", "value": "console-plugin-nvidia-gpu" }]' --type=json
# else
#     echo -e "\tℹ️  NVIDIA GPU Console Plugin already enabled, skipping patch."
# fi


echo -e "\n📊 ====================="
echo -e "📊 =   Observability   ="
echo -e "📊 =====================\n"

if [[ "$INSTALL_MONITORING" =~ ^([Tt]rue|[Yy]es|[1])$ ]]; then

    echo -e "\n🏷️  Label all non-gpu worker nodes for simplicity. Not for production use"
    for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
        # Check if the node does not have a GPU-related label or resource
        if ! oc describe $node | grep -q "nvidia.com/gpu"; then
            # Label the node as a non-GPU worker
            oc label $node node-role.kubernetes.io/infra=
        fi
    done

    echo -e "\t📈 Enable User Workload monitoring for TrustAI."
    oc apply -f https://raw.githubusercontent.com/alvarolop/quarkus-observability-app/refs/heads/main/apps/application-ocp-monitoring.yaml

else
    echo -e "\n⏭️  Skip Monitoring configuration..."
fi

echo -e "\n🔧 ====================="
echo -e "🔧 =   OCP Pipelines   ="
echo -e "🔧 =====================\n"

if [[ "$INSTALL_PIPELINES" =~ ^([Tt]rue|[Yy]es|[1])$ ]]; then

    echo -e "\n🚰 Install the OCP Pipelines operator to load Kubeflow pipelines to RHOAI"
    oc apply -k ocp-pipelines
else
    echo -e "\n⏭️  Skip OCP Pipelines installation..."
fi 

echo -e "\n🗂️ ======================"
echo -e "🗂️ = MinIO Installation ="
echo -e "🗂️ ======================\n"

if [[ "$INSTALL_MINIO" =~ ^([Tt]rue|[Yy]es|[1])$ ]]; then

    MINIO_NAMESPACE="minio"
    MINIO_SERVICE_NAME="minio"
    MINIO_ADMIN_USERNAME="minio"
    MINIO_ADMIN_PASSWORD="minio123"

    echo -e "1️⃣ Trigger the ArgoCD application to install MinIO instance"
    cat application-minio.yaml | \
    CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}') \
    MINIO_NAMESPACE=$MINIO_NAMESPACE MINIO_SERVICE_NAME=$MINIO_SERVICE_NAME \
    MINIO_ADMIN_USERNAME=$MINIO_ADMIN_USERNAME MINIO_ADMIN_PASSWORD=$MINIO_ADMIN_PASSWORD \
    envsubst | oc apply -f -

    echo -e "\n2️⃣ Wait 10 seconds for resources to be created"
    for i in {10..1}; do
        echo -ne "\t⏰ Time left: $i seconds.\r"; sleep 1
    done

    echo -e "\n3️⃣ Let's wait until all the pods are up and running"
    while oc get pods -n $MINIO_NAMESPACE | grep -v "Running\|Completed\|NAME"; do echo "⏳ Waiting..."; sleep 10; done

    if [[ "$CREATE_RHOAI_ENV" =~ ^([Tt]rue|[Yy]es|[1])$ ]]; then
        ./prerequisites/s3-bucket/create-minio-s3-bucket.sh minio minio # TODO: remove the AWS dependency
    else
        echo "⏭️  Skip creation of RHOAI Playground environment MinIO Bucket..."
    fi

else
    echo "⏭️  Skip installation of MinIO..."
fi

echo -e "\n💾 ======================"
echo -e "💾 =  ODF Installation  ="
echo -e "💾 ======================\n"

if [[ "$INSTALL_ODF" =~ ^([Tt]rue|[Yy]es|[1])$ ]]; then

    echo -e "\n1️⃣ Label all non-GPU worker nodes to storage nodes for simplicity. Not for production use"
    for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name | grep -v "gpu-worker"); do
        oc label $node cluster.ocs.openshift.io/openshift-storage=""
        oc label $node node-role.kubernetes.io/infra=""
    done

    echo -e "\n2️⃣ Trigger the ArgoCD application to install ODF and create the Multicloud Object Gateway"
    oc apply -f application-ocp-odf.yaml

    echo -e "\n3️⃣ Enable the console plugin..."
    if oc get console.operator.openshift.io cluster -o template='{{.spec.plugins}}' | grep odf-console &> /dev/null; then
        echo -e "\t✅ Checked. The logging plugin was already enabled."
    else
        echo -e "\t🔧 Checked. The logging plugin was not enabled. Enabling..."
        oc patch console.operator.openshift.io cluster --type json \
        --patch '[{"op": "add", "path": "/spec/plugins/-", "value": "odf-console"}]'
    fi

    echo -e "\n4️⃣ Waiting for StorageCluster and components to be ready..."
    until [[ "$(oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.status.phase}')" == "Ready" && \
            #  "$(oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.health}')" == "HEALTH_OK" && \
            "$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}')" == "Ready" ]]; do
        echo "⏳ Waiting for StorageCluster and components to be fully ready..."
        sleep 30
    done
    echo "✅ StorageCluster is ready and all components are healthy."
else
    echo "⏭️  Skip installation of ODF..."
fi

echo -e "\n🚀 ==================="
echo -e "🚀 = GPU NODES READY ="
echo -e "🚀 ===================\n"

if [[ "$CREATE_GPU_MACHINESETS" =~ ^([Tt]rue|[Yy]es|[1])$ ]] && [[ "$GPU_NODE_COUNT" -gt 0 ]]; then
    echo "🔍 This script waits until there is at least one node discovered as NVIDIA GPU node by the Node Feature Discovery Operator."
    echo "🔎 It checks every 15 seconds to see if nodes with the feature.node.kubernetes.io/pci-10de.present=true label are available."
    echo "💡 0x10de is the PCI vendor ID that is assigned to NVIDIA."
    # https://docs.nvidia.com/datacenter/cloud-native/openshift/24.6.2/install-nfd.html#verify-that-the-node-feature-discovery-operator-is-functioning-correctly

    while [[ $(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o go-template='{{ len .items }}') -eq 0 ]]; do
    echo "⏳ No nodes found, waiting..."
    sleep 15
    done
    echo "🎉 Nodes found!"
else
    echo "⏭️  Skip waiting for NVIDIA gpu nodes..."
fi

echo -e "\n🤖 ======================"
echo -e "🤖 = RHOAI Installation ="
echo -e "🤖 ======================\n"

echo -e "\n🚀 Trigger the ArgoCD application to install RHOAI instance"
oc apply -f application-rhoai-installation.yaml

echo -e "\n⏰ Wait 15 seconds for resources to be created"
for i in {15..1}; do
    echo -ne "\t⏰ Time left: $i seconds.\r"; sleep 1
done

echo -e "⏳ Waiting until all the pods are up and running"
while oc get pods -n redhat-ods-applications | grep -v "Running\|Completed\|NAME"; do echo "⏳ Waiting..."; sleep 10; done

echo -e "\n🎉 You should be able now to access the RHOAI dashboard"

echo "💡 If you access the RHOAI dashboard > Settings > Cluster Settings and any of the model servings are not available, try restarting the dashboard pods:"
echo -e "\t🔄 oc delete pods -l app=rhods-dashboard -n redhat-ods-applications"


echo -e "\n🛠️ =========================="
echo -e "🛠️ = Post Install utilities ="
echo -e "🛠️ ==========================\n"

if [[ "$CREATE_RHOAI_ENV" =~ ^([Tt]rue|[Yy]es|[1])$ ]]; then
    echo -e "🎮 Trigger the ArgoCD application to deploy the RHOAI Playground environment"
    oc apply -f application-rhoai-playground-env.yaml
else
    echo "⏭️  Skip creation of RHOAI Playground environment..."
fi

if [[ "$INSTALL_LANGFUSE" =~ ^([Tt]rue|[Yy]es|[1])$ ]] && [[ "$INSTALL_MINIO" =~ ^([Tt]rue|[Yy]es|[1])$ ]]; then
    echo "🚀 Installing Langfuse via ArgoCD application"
    MINIO_NAMESPACE="${MINIO_NAMESPACE:-minio}"
    MINIO_SERVICE_NAME="${MINIO_SERVICE_NAME:-minio}"
    MINIO_ADMIN_USERNAME="${MINIO_ADMIN_USERNAME:-minio}"
    MINIO_ADMIN_PASSWORD="${MINIO_ADMIN_PASSWORD:-minio123}"
    cat application-langfuse.yaml | \
    CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}') \
    MINIO_NAMESPACE=$MINIO_NAMESPACE MINIO_SERVICE_NAME=$MINIO_SERVICE_NAME \
    MINIO_ADMIN_USERNAME=$MINIO_ADMIN_USERNAME MINIO_ADMIN_PASSWORD=$MINIO_ADMIN_PASSWORD \
    envsubst | oc apply -f -
else
    echo "⏭️  Skip installation of Langfuse (requires INSTALL_LANGFUSE and INSTALL_MINIO enabled)..."
fi

echo "🎊 That's all!! RHOAI should be up and running!! :)"
