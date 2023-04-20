FROM lambci/lambda:build-python3.8

ARG JENKINS_UID=386
ARG JENKINS_GID=386

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && \
  unzip awscliv2.zip && \
  ./aws/install && \
  rm -rf aws awscliv2.zip

RUN curl -sL https://rpm.nodesource.com/setup_14.x | bash - \
  && yum install -y nodejs

RUN npm install -g serverless

# Create the jenkins user with the same id:gid as the jenkins node
RUN groupadd -g $JENKINS_GID jenkins \
  && useradd -m -d /var/lib/jenkins -u $JENKINS_UID -g jenkins jenkins

USER jenkins
