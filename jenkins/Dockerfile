FROM node:18

ARG JENKINS_UID=386
ARG JENKINS_GID=386
ARG DOCKER_GID=999

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip

# install docker cli
RUN wget -q -O /tmp/docker-cli.deb https://download.docker.com/linux/debian/dists/bullseye/pool/stable/$(dpkg --print-architecture)/docker-ce-cli_20.10.9~3-0~debian-bullseye_$(dpkg --print-architecture).deb \
  && dpkg -i /tmp/docker-cli.deb

# Install Python 3.8 for serverless (keep this in line with the runtime in serverless.yml)
env PYTHON_VERSION=3.8.15
RUN curl -O https://cdn.rstudio.com/python/debian-11/pkgs/python-${PYTHON_VERSION}_1_amd64.deb \
  && apt update -qq \
  && DEBIAN_FRONTEND=noninteractive  apt install -y ./python-3.8.15_1_amd64.deb \
  && ln -s /opt/python/${PYTHON_VERSION}/bin/python3.8 /usr/local/bin/python3.8 \
  && rm python-${PYTHON_VERSION}_1_amd64.deb

RUN npm install -g serverless

# Create the jenkins user with the same id:gid as the jenkins node
RUN groupadd -g $JENKINS_GID jenkins \
  && useradd -m -d /var/lib/jenkins -u $JENKINS_UID -g jenkins jenkins

# create docker group, add jenkins user to it
RUN groupadd -g $DOCKER_GID docker \
  && usermod -aG docker jenkins

USER jenkins
