FROM node:16

ARG JENKINS_UID=386
ARG JENKINS_GID=386
ARG DOCKER_GID=999

RUN apt-get update -qq && apt-get install -y python-pip
RUN pip install awscli

# install docker cli
RUN wget -q -O /tmp/docker-cli.deb https://download.docker.com/linux/debian/dists/stretch/pool/stable/amd64/docker-ce-cli_18.09.2~3-0~debian-stretch_amd64.deb \
  && dpkg -i /tmp/docker-cli.deb

RUN npm install -g serverless

# Create the jenkins user with the same id:gid as the jenkins node
RUN groupadd -g $JENKINS_GID jenkins \
  && useradd -m -d /var/lib/jenkins -u $JENKINS_UID -g jenkins jenkins

# create docker group, add jenkins user to it
RUN groupadd -g $DOCKER_GID docker \
  && usermod -aG docker jenkins

USER jenkins
