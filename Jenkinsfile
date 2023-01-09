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
        branch 'main'
      }
      steps {
        sh 'make docker-push'
      }
    }
    stage('deploy') {
      agent none
      when {
        branch 'main'
      }
      steps {
        build(job: 'r-builds/deploy-r-builds', wait: true,
              parameters: [string(name: 'ENVIRONMENT', value: 'staging')])
      }
    }
  }
}
