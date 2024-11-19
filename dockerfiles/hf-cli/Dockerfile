FROM registry.access.redhat.com/ubi9-minimal:latest

# Install EPEL for s3cmd and awscli
RUN rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

RUN microdnf install -y unzip pip s3cmd awscli \
    && microdnf clean all

# Install huggingface hub cli without cache directory
RUN pip install --no-cache-dir -U "huggingface_hub[cli]" && \
    rm -rf /root/.cache
