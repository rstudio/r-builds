pipeline {
  agent none
  environment {
    HOME = "."
  }
  options {
    ansiColor('xterm')
  }
  stages {
    stage('build images') {
      agent { label 'docker-4x' }
      steps {
        sh 'make docker-build'
      }
    }
    stage('push images') {
      agent { label 'docker-4x' }
      when {
        branch 'master'
      }
      steps {
        sh 'make docker-push'
      }
    }
    stage('deploy') {
      agent {
        dockerfile {
          dir 'jenkins'
          label 'docker-4x'
          additionalBuildArgs '--build-arg DOCKER_GID=$(stat -c %g /var/run/docker.sock) --build-arg JENKINS_UID=$(id -u jenkins) --build-arg JENKINS_GID=$(id -g jenkins)'
          args '-v /var/run/docker.sock:/var/run/docker.sock --group-add docker'
        }
      }
      when {
        branch 'master'
      }
      steps {
        sh 'make serverless-deploy.production'
      }
    }
  }
}
