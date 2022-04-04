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
           description: 'The target environment to build to.')
    string(name: 'PARAMS', defaultValue: '{"force": true}',
           description: 'Build parameters.')
  }
  stages {
    stage('build') {
      steps {
        withAWS(role:'r-builds-deploy') {
          sh "make deps"
          sh "make fetch-serverless-custom-file"
          sh "./node_modules/.bin/serverless invoke stepf -n rBuilds -s ${params.ENVIRONMENT} -d \'${params.PARAMS}\'"
        }
      }
    }
  }
}
