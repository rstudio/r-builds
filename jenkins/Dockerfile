# We don't use the public.ecr.aws/sam/build-python or older lambci/lambda:build-python
# images because they're tied to distros that make dependencies hard to maintain.
# For example, the current 3.8-3.10 images are based on Amazon Linux 2, which no longer
# supports newer versions of Node.

FROM ubuntu:jammy

ARG JENKINS_UID=386
ARG JENKINS_GID=386

# Keep the Python version in line with the runtime in serverless.yml
ARG PYTHON_VERSION=3.8.15

RUN apt update -qq \
  && apt install -y \
  curl \
  make \
  unzip

RUN curl -O https://cdn.rstudio.com/python/ubuntu-2204/pkgs/python-${PYTHON_VERSION}_1_amd64.deb \
  && apt update -qq \
  && apt install -y ./python-${PYTHON_VERSION}_1_amd64.deb \
  && ln -s /opt/python/${PYTHON_VERSION}/bin/* /usr/local/bin/ \
  && rm python-${PYTHON_VERSION}_1_amd64.deb

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf aws awscliv2.zip

# Install Node
RUN curl -fsSL https://deb.nodesource.com/setup_16.x | bash - \
  && apt update -qq \
  && apt install -y nodejs

RUN npm install -g serverless

# Create the jenkins user with the same id:gid as the jenkins node
RUN groupadd -g $JENKINS_GID jenkins \
  && useradd -m -d /var/lib/jenkins -u $JENKINS_UID -g jenkins jenkins

USER jenkins
