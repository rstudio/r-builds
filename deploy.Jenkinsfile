pipeline {
  agent {
    dockerfile {
      dir 'jenkins'
      label 'docker'
      // Required for the serverless-python-requirements plugin to install
      // Python requirements using the AWS build images, running Docker inside Docker.
      additionalBuildArgs '--build-arg DOCKER_GID=$(stat -c %g /var/run/docker.sock) --build-arg JENKINS_UID=$(id -u jenkins) --build-arg JENKINS_GID=$(id -g jenkins)'
      args '-v /var/run/docker.sock:/var/run/docker.sock --group-add docker'
    }
  }
  environment {
    // Set HOME to the workspace for the serverless-python-requirements plugin.
    // The plugin uses HOME for its default cache location, which needs to be
    // mounted in the separate Python build container. This needs to be an absolute
    // path that also exists on the host since we're mounting the Docker socket.
    HOME = "${env.WORKSPACE}"
  }
  options {
    ansiColor('xterm')
  }
  parameters {
    choice(name: 'ENVIRONMENT', choices: ['staging', 'production'],
           description: 'The target environment to deploy to.')
  }
  stages {
    stage('deploy') {
      steps {
        withAWS(role:'r-builds-deploy') {
          sh "make serverless-deploy.${params.ENVIRONMENT}"
        }
      }
    }
  }
}
