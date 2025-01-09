#!/bin/sh

AWS_VARS_FILE=aws-env-vars
NOTEBOOK_NAMESPACE=rhoai-playground

source ./$AWS_VARS_FILE

# User defined variables
BUCKET_SECRET_NAME="dspa-pipelines-connection-secret"
AWS_S3_BUCKET="$NOTEBOOK_NAMESPACE-$BUCKET_SECRET_NAME"

# Print environment variables
echo -e "\n=============="
echo -e "ENVIRONMENT VARIABLES:"
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

if aws s3api head-bucket --bucket $AWS_S3_BUCKET &> /dev/null; then
    echo -e "Check. S3 bucket already exists, do nothing."
else
    echo -e "Check. Creating S3 bucket..."
    aws s3api create-bucket \
    --bucket $AWS_S3_BUCKET \
    --region $AWS_DEFAULT_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION
fi

echo -e "\nCreate the Pipelines Datasource Secret"
oc new-project $NOTEBOOK_NAMESPACE
oc process -f ./prerequisites/s3-bucket/secret-data-connection-pipelines.yaml \
    --param-file $AWS_VARS_FILE --ignore-unknown-parameters=true \
    -p NOTEBOOK_NAMESPACE=$NOTEBOOK_NAMESPACE \
    -p AWS_S3_BUCKET=$AWS_S3_BUCKET | oc apply -f -
