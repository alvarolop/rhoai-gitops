#!/bin/sh

set -e

source ./aws-env-vars

#####################################
# Set your environment variables here
#####################################


CREATE_AWS_MACHINESETS=true
INSTALL_ODF=true
CREATE_RHOAI_ENV=true

#####################################
## Do not modify anything from this line
#####################################

# Print environment variables
echo -e "\n===================="
echo -e "ENVIRONMENT VARIABLES:"
# echo -e " * LOKI_BUCKET: $LOKI_BUCKET"
# echo -e " * LOKI_SECRET_NAMESPACE: $LOKI_SECRET_NAMESPACE"
# echo -e " * TEMPO_BUCKET: $TEMPO_BUCKET"
# echo -e " * TEMPO_SECRET_NAMESPACE: $TEMPO_SECRET_NAMESPACE"
echo -e "====================\n"

# Check if the user is logged in 
if ! oc whoami &> /dev/null; then
    echo -e "Check. You are not logged out. Please log in and run the script again."
    exit 1
else
    echo -e "Check. You are correctly logged in. Continue..."
    if ! oc project &> /dev/null; then
        echo -e "Current project does not exist, moving to project Default."
        oc project default 
    fi
fi

echo -e "\n=================="
echo -e "=    GPU INFRA   ="
echo -e "==================\n"

if [ "$CREATE_AWS_MACHINESETS" = true ]; then
    echo "Adding GPU nodes to the cluster. Adding three availability zones for the future, but only one node in AZ a."

    oc process -f prerequisites/ocp-nodes/template-gpu-worker.yaml \
        -p INFRASTRUCTURE_ID=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster) \
        -p INSTANCE_TYPE="g5.4xlarge" -p AZ="a" -p REPLICAS=1 | \
        oc apply -n openshift-machine-api -f -

    oc process -f prerequisites/ocp-nodes/template-gpu-worker.yaml \
        -p INFRASTRUCTURE_ID=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster) \
        -p INSTANCE_TYPE="g5.4xlarge" -p AZ="b" -p REPLICAS=0 | \
        oc apply -n openshift-machine-api -f -

    oc process -f prerequisites/ocp-nodes/template-gpu-worker.yaml \
        -p INFRASTRUCTURE_ID=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster) \
        -p INSTANCE_TYPE="g5.4xlarge" -p AZ="c" -p REPLICAS=0 | \
        oc apply -n openshift-machine-api -f -

    echo -e "\nRemember, those nodes are tainted with 'nvidia.com/gpu:NoSchedule' by default. Modify the template or update the node definition if you want to run normal workloads"
else
    echo "Skip creation of NVIDIA gpu nodes..."
fi

echo -e "\n====================="
echo -e "= Install Operators ="
echo -e "=====================\n"

echo -e "1) Trigger the ArgoCD application to install the operators"
oc apply -f application-rhoai-dependencies.yaml


echo -e "\n2) Wait 30 seconds for Subscriptions to be applied"
for i in {30..1}; do
  echo -ne "\tTime left: $i seconds.\r"
  sleep 1
done

# Wait for all operators to be in 'Succeeded' state
echo -e "\n3) Waiting for all operators to be in 'Succeeded' state..."
until [[ -z $(oc get csv --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' | grep -v "Succeeded") ]]; do
    echo "Some operators are not in 'Succeeded' state, retrying in 20 seconds..."
    oc get csv --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' | grep -v "Succeeded"
    sleep 10
done
echo -e "\tAll operators are in 'Succeeded' state."



echo -e "\n======================"
echo -e "=  ODF Installation  ="
echo -e "======================\n"

if [ "$INSTALL_ODF" = true ]; then
    echo -e "\n1) Label all non-GPU worker nodes to storage nodes for simplicity. Not for production use"
    for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name | grep -v "gpu-worker"); do
        oc label $node cluster.ocs.openshift.io/openshift-storage=""
        oc label $node node-role.kubernetes.io/infra=""
    done

    echo -e "\n2) Trigger the ArgoCD application to install ODF and create the Multicloud Object Gateway"
    oc apply -f application-ocp-odf-mcg.yaml

    echo -e "\n3) Enable the console plugin..."
    if oc get console.operator.openshift.io cluster -o template='{{.spec.plugins}}' | grep odf-console &> /dev/null; then
        echo -e "\tChecked. The logging plugin was already enabled."
    else
        echo -e "\tChecked. The logging plugin was not enabled. Enabling..."
        oc patch console.operator.openshift.io cluster --type json \
        --patch '[{"op": "add", "path": "/spec/plugins/-", "value": "odf-console"}]'
    fi

    echo -e "\n4) Waiting for StorageCluster and components to be ready..."
    until [[ "$(oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.status.phase}')" == "Ready" && \
            #  "$(oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.health}')" == "HEALTH_OK" && \
            "$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}')" == "Ready" ]]; do
        echo "Waiting for StorageCluster and components to be fully ready..."
        sleep 30
    done
    echo "StorageCluster is ready and all components are healthy."
else
    echo "Skip installation of ODF..."
fi

echo -e "\n==================="
echo -e "= GPU NODES READY ="
echo -e "===================\n"

echo "This script waits until there is at least one node discovered as NVIDIA GPU node by the Node Feature Discovery Operator."
echo "It checks every 5 seconds to see if nodes with the feature.node.kubernetes.io/pci-10de.present=true label are available."
# https://docs.nvidia.com/datacenter/cloud-native/openshift/24.6.2/install-nfd.html#verify-that-the-node-feature-discovery-operator-is-functioning-correctly

while [[ $(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o go-template='{{ len .items }}') -eq 0 ]]; do
  echo "No nodes found, waiting..."
  sleep 5
done
echo "Nodes found!"


echo -e "\n======================"
echo -e "= RHOAI Installation ="
echo -e "======================\n"

echo -e "Trigger the ArgoCD application to install RHOAI instance"
oc apply -f application-rhoai-installation.yaml

echo -e "\nLet's wait until all the pods are up and running"
while oc get pods -n redhat-ods-applications | grep -v "Running\|Completed\|NAME"; do echo "Waiting..."; sleep 10; done

echo ""
echo "You should be able now to access the RHOAI dashboard"

echo "If you access the RHOAI dashboard > Settings > Cluster Settings and any of the model servings are not available, try restarting the dashboard pods:"
echo -e "\toc delete pods -l app=rhods-dashboard -n redhat-ods-applications"


echo -e "\n=========================="
echo -e "= Post Install utilities ="
echo -e "==========================\n"

if [ "$CREATE_RHOAI_ENV" = true ]; then
    echo -e "Trigger the ArgoCD application to deploy the RHOAI Playground environment"
    oc apply -f application-rhoai-playground-env.yaml
else
    echo "Skip creation of RHOAI Playground environment..."
fi

echo "That's all!! RHOAI should be up and running!! :)"
 





# echo -e "\nWaiting for ObjectBucketClaim for Tempo to be ready..."

# until [[ "$(oc get objectbucketclaim tempo-bucket-odf -n openshift-tempo-operator -o jsonpath='{.status.phase}')" == "Bound" ]]; do
#     echo "Waiting for ObjectBucketClaim 'tempo-bucket-odf' to be bound..."
#     sleep 10
# done

# echo "ObjectBucketClaim 'tempo-bucket-odf' is ready."



#
# This section is no longer  needed as Kiali is not required for this
# 

# Get the list of install plans with manual approval and not in Complete status
# echo "Looking for an existing approved Kiali InstallPlan..."
# approved_plan=$(oc get installplan -n openshift-operators -o jsonpath='{.items[?(@.spec.approval=="Manual" && @.status.phase=="Complete")].metadata.name}' 2>/dev/null | grep 'kiali' | head -n 1)

# if [[ -n "$approved_plan" ]]; then
#   echo "An approved InstallPlan for Kiali already exists: ${approved_plan}. Skipping approval process."
# else
#   echo "No approved Kiali InstallPlan found. Looking for a pending InstallPlan to approve..."
#   install_plan=$(oc get installplan -n openshift-operators -o jsonpath='{.items[?(@.spec.approval=="Manual")].metadata.name}' 2>/dev/null | grep -v 'Complete' | grep 'kiali' | head -n 1)

#   if [[ -n "$install_plan" ]]; then
#     echo "Pending InstallPlan found: ${install_plan}, approving..."
#     oc patch installplan "$install_plan" -n openshift-operators --type merge --patch '{"spec": {"approved": true}}'
#     echo "InstallPlan ${install_plan} approved."
#   else
#     echo "No pending InstallPlan found, continuing..."
#   fi
# fi