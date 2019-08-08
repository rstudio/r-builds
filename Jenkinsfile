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
    stage('test images') {
      parallel {
        stage('R 3.1') {
          agent { label 'docker' }
          steps {
            sh 'R_VERSION=3.1.3 make docker-build-r'
            sh 'R_VERSION=3.1.3 make docker-test-r'
          }
        }
        stage('R 3.2') {
          agent { label 'docker' }
          steps {
            sh 'R_VERSION=3.2.5 make docker-build-r'
            sh 'R_VERSION=3.2.5 make docker-test-r'
          }
        }
        stage('R 3.3') {
          agent { label 'docker' }
          steps {
            sh 'R_VERSION=3.3.3 make docker-build-r'
            sh 'R_VERSION=3.3.3 make docker-test-r'
          }
        }
        stage('R 3.4') {
          agent { label 'docker' }
          steps {
            sh 'R_VERSION=3.4.4 make docker-build-r'
            sh 'R_VERSION=3.4.4 make docker-test-r'
          }
        }
        stage('R 3.5') {
          agent { label 'docker' }
          steps {
            sh 'R_VERSION=3.5.3 make docker-build-r'
            sh 'R_VERSION=3.5.3 make docker-test-r'
          }
        }
        stage('R 3.6') {
          agent { label 'docker' }
          steps {
            sh 'R_VERSION=3.6.1 make docker-build-r'
            sh 'R_VERSION=3.6.1 make docker-test-r'
          }
        }
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
        sh 'make serverless-deploy'
      }
    }
  }
}
