pipeline {
  agent {
    dockerfile {
      dir 'jenkins'
      label 'docker'
    }
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
