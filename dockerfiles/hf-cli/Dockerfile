FROM registry.access.redhat.com/ubi9-minimal:latest

# Install dependencies
RUN microdnf install -y unzip pip \
    && microdnf clean all

# Install huggingface hub cli without cache directory
RUN pip install --no-cache-dir -U "huggingface_hub[cli]" && \
    rm -rf /root/.cache

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && rm -rf awscliv2.zip \
    && ./aws/install
