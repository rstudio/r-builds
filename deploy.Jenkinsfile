pipeline {
  agent {
    dockerfile {
      dir 'jenkins'
      label 'docker'
    }
  }
  environment {
    // Set HOME to the workspace for the serverless-python-requirements plugin.
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
