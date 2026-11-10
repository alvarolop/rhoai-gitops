#!/bin/bash
# Usage: S4_S3_ACCESS_KEY=... S4_S3_SECRET_KEY=... ./create-s4-bucket.sh <s4-namespace> <s4-service-name> <bucket> [region]

S4_NAMESPACE=${1:?s4 namespace is required}
S4_SERVICE_NAME=${2:?s4 service name is required}
S4_BUCKET=${3:?bucket name is required}
S4_S3_REGION=${4:-us-east-1}

export AWS_ACCESS_KEY_ID="${S4_S3_ACCESS_KEY:?S4_S3_ACCESS_KEY is required}"
export AWS_SECRET_ACCESS_KEY="${S4_S3_SECRET_KEY:?S4_S3_SECRET_KEY is required}"
export AWS_DEFAULT_REGION="$S4_S3_REGION"

if ! which aws &> /dev/null; then
    echo "You need the AWS CLI to run this script, please, refer to the official documentation:"
    echo -e "\thttps://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# The S3 API Route is named <release>-api; it may need a few seconds to serve traffic.
S4_ENDPOINT_ROUTE="$(oc get routes -n $S4_NAMESPACE $S4_SERVICE_NAME-api --template='https://{{ .spec.host }}')" || exit 1

for attempt in 1 2 3 4 5 6; do
    if aws --endpoint-url=$S4_ENDPOINT_ROUTE s3api head-bucket --bucket $S4_BUCKET &> /dev/null; then
        echo -e "Check. S3 bucket '$S4_BUCKET' already exists, do nothing."
        exit 0
    elif aws --endpoint-url=$S4_ENDPOINT_ROUTE s3api create-bucket --bucket $S4_BUCKET; then
        echo -e "Check. S3 bucket '$S4_BUCKET' created."
        exit 0
    fi
    echo -e "⏳ S4 S3 API not ready, retrying in 10 seconds ($attempt/6)..."
    sleep 10
done

echo -e "❌ Could not create the S3 bucket '$S4_BUCKET' in S4."
exit 1
