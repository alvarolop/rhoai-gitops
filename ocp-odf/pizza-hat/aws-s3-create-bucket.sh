#!/bin/sh

# set -xe

AWS_S3_BUCKET=$1

# Print environment variables
# echo -e "\n=============="
# echo -e "ENVIRONMENT VARIABLES:"
# echo -e " * AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
# echo -e " * AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY"
# echo -e " * AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
# echo -e " * AWS_S3_BUCKET: $AWS_S3_BUCKET"
# echo -e "==============\n"

if ! which aws &> /dev/null; then 
    echo "You need the AWS CLI to run this Quickstart, please, refer to the official documentation:"
    echo -e "\thttps://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

if aws s3api head-bucket --bucket $AWS_S3_BUCKET &> /dev/null; then
    echo -e "Check. S3 bucket already exists, do nothing."
    exit 0
else
    echo -e "Check. Creating S3 bucket..."
fi

aws s3api create-bucket \
    --bucket $AWS_S3_BUCKET \
    --region $AWS_DEFAULT_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION
