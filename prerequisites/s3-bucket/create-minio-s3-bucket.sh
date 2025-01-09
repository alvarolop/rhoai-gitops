#!/bin/sh

NOTEBOOK_NAMESPACE=rhoai-playground

# User defined variables
BUCKET_SECRET_NAME="dspa-pipelines-connection-secret"
AWS_S3_BUCKET="$NOTEBOOK_NAMESPACE-$BUCKET_SECRET_NAME"

# MinIO-specific variables
MINIO_ENDPOINT_ROUTE="$(oc get routes -n ic-shared-minio minio-api --template='https://{{ .spec.host }}')"
MINIO_ENDPOINT_SVC="https://minio-api.ic-shared-minio.svc.cluster.local"

export AWS_ACCESS_KEY_ID="$(oc get secret minio -n ic-shared-minio -o jsonpath='{.data.minio_root_user}' | base64 --decode)"
export AWS_SECRET_ACCESS_KEY="$(oc get secret minio -n ic-shared-minio -o jsonpath='{.data.minio_root_password}' | base64 --decode)"
export AWS_DEFAULT_REGION="local"            # Keep this for compatibility

# Print environment variables
echo -e "\n=============="
echo -e "ENVIRONMENT VARIABLES:"
echo -e " * MINIO_ENDPOINT_ROUTE: $MINIO_ENDPOINT_ROUTE"
echo -e " * AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
echo -e " * AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY"
echo -e " * AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
echo -e " * AWS_S3_BUCKET: $AWS_S3_BUCKET"
echo -e " * NOTEBOOK_NAMESPACE: $NOTEBOOK_NAMESPACE"
echo -e "==============\n"

if ! which aws &> /dev/null; then 
    echo "You need the AWS CLI to run this Quickstart, please, refer to the official documentation:"
    echo -e "\thttps://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Check if the bucket exists in MinIO
if aws --endpoint-url=$MINIO_ENDPOINT_ROUTE s3api head-bucket \
    --bucket $AWS_S3_BUCKET &> /dev/null; then
    echo -e "Check. S3 bucket already exists, do nothing."
else
    echo -e "Check. Creating S3 bucket..."
    aws --endpoint-url=$MINIO_ENDPOINT_ROUTE s3api create-bucket \
    --bucket $AWS_S3_BUCKET \
    --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION
fi 

echo -e "\nCreate the Pipelines Datasource Secret"
oc get project $NOTEBOOK_NAMESPACE || oc new-project $NOTEBOOK_NAMESPACE
oc process -f ./prerequisites/s3-bucket/secret-data-connection-pipelines.yaml \
    -p AWS_S3_ENDPOINT=$MINIO_ENDPOINT_SVC \
    -p AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
    -p AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    -p AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION \
    -p NOTEBOOK_NAMESPACE=$NOTEBOOK_NAMESPACE \
    -p AWS_S3_BUCKET=$AWS_S3_BUCKET | oc apply -f -
