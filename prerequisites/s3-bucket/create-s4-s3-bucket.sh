#!/bin/bash
# Usage: S4_S3_ACCESS_KEY=... S4_S3_SECRET_KEY=... ./create-s4-s3-bucket.sh <s4-namespace> <s4-service-name> <region>

NOTEBOOK_NAMESPACE=rhoai-playground

S4_NAMESPACE=${1:-s4}
S4_SERVICE_NAME=${2:-s4}
S4_S3_REGION=${3:-us-east-1}

# User defined variables
BUCKET_SECRET_NAME="dspa-pipelines-connection-secret"
AWS_S3_BUCKET="$NOTEBOOK_NAMESPACE-$BUCKET_SECRET_NAME"

S4_ENDPOINT_SVC="http://$S4_SERVICE_NAME.$S4_NAMESPACE.svc.cluster.local:7480"

export AWS_ACCESS_KEY_ID="${S4_S3_ACCESS_KEY:?S4_S3_ACCESS_KEY is required}"
export AWS_SECRET_ACCESS_KEY="${S4_S3_SECRET_KEY:?S4_S3_SECRET_KEY is required}"
export AWS_DEFAULT_REGION="$S4_S3_REGION"

# Print environment variables
echo -e "\n=============="
echo -e "ENVIRONMENT VARIABLES:"
echo -e " * S4_ENDPOINT_SVC: $S4_ENDPOINT_SVC"
echo -e " * AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
echo -e " * AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
echo -e " * AWS_S3_BUCKET: $AWS_S3_BUCKET"
echo -e " * NOTEBOOK_NAMESPACE: $NOTEBOOK_NAMESPACE"
echo -e "==============\n"

"$(dirname "$0")/create-s4-bucket.sh" "$S4_NAMESPACE" "$S4_SERVICE_NAME" "$AWS_S3_BUCKET" "$S4_S3_REGION" || exit 1

echo -e "\nCreate the Pipelines Datasource Secret"
oc get project $NOTEBOOK_NAMESPACE || oc new-project $NOTEBOOK_NAMESPACE
oc process -f ./prerequisites/s3-bucket/secret-data-connection-pipelines.yaml \
    -p SECRET_NAME=$BUCKET_SECRET_NAME \
    -p AWS_S3_ENDPOINT=$S4_ENDPOINT_SVC \
    -p AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
    -p AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    -p AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION \
    -p NOTEBOOK_NAMESPACE=$NOTEBOOK_NAMESPACE \
    -p AWS_S3_BUCKET=$AWS_S3_BUCKET | oc apply -f -
