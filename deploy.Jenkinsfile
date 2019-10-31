pipeline {
  agent {
    dockerfile {
      dir 'jenkins'
      label 'docker'
      additionalBuildArgs '--build-arg DOCKER_GID=$(stat -c %g /var/run/docker.sock) --build-arg JENKINS_UID=$(id -u jenkins) --build-arg JENKINS_GID=$(id -g jenkins)'
      args '-v /var/run/docker.sock:/var/run/docker.sock --group-add docker'
    }
  }
  environment {
    HOME = "."
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
        sh 'make serverless-deploy.${params.ENVIRONMENT}'
      }
    }
  }
}
