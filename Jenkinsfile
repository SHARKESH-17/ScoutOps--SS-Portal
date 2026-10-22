// ScoutOps declarative pipeline.
// Runs on a Jenkins AGENT labelled "docker" that has Git, Node.js 22 + npm, Docker Engine
// + Compose plugin and curl installed (see README -> Jenkins Setup).
// No secrets live in this file: the production .env is injected from the Jenkins
// credential "scoutops-env-file" (type: Secret file) and deleted when the build ends.
pipeline {
  agent { label 'java-node' }

  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    skipDefaultCheckout(true)
  }

  triggers {
    githubPush()
  }

  environment {
    // MAJOR.MINOR.PATCH tag so scripts/rollback.sh can order versions: 1.0.<build number>
    SCOUTOPS_VERSION = "1.0.${BUILD_NUMBER}"
    HEALTH_URL       = 'http://localhost:3000'   // change if APP_PORT differs in your env file
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        sh 'git log -1 --oneline'
      }
    }

    stage('Install Dependencies') {
      steps {
        sh '''
          set -e
          node --version
          npm --version
          if [ -f package-lock.json ]; then npm ci; else npm install; fi
        '''
      }
    }

    stage('Run Tests') {
      steps {
        sh 'npm test'
      }
    }

    stage('Build Docker Image') {
      steps {
        sh 'docker build -t scoutops:${SCOUTOPS_VERSION} -t scoutops:latest .'
      }
    }

    stage('Validate') {
      steps {
        withCredentials([file(credentialsId: 'scoutops-env-file', variable: 'ENV_FILE')]) {
          sh '''
            set -e
            cp "$ENV_FILE" .env
            chmod 600 .env
            for f in scripts/*.sh; do bash -n "$f"; done
            docker compose -f docker-compose.prod.yml config -q
            docker compose --env-file .env -f monitoring/docker-compose.monitoring.yml config -q
            docker image inspect scoutops:${SCOUTOPS_VERSION} > /dev/null
          '''
        }
      }
    }

    stage('Deploy') {
      when {
        // Plain Pipeline jobs have no BRANCH_NAME; multibranch jobs deploy main only.
        expression { return !env.BRANCH_NAME || env.BRANCH_NAME == 'main' }
      }
      steps {
        withCredentials([file(credentialsId: 'scoutops-env-file', variable: 'ENV_FILE')]) {
          sh '''
            set -e
            cp "$ENV_FILE" .env
            chmod 600 .env
            ./scripts/deploy.sh --no-build
          '''
        }
      }
    }

    stage('Health Check') {
      steps {
        sh '''
          set -e
          for path in /health /health/db; do
            ok=0
            for i in 1 2 3 4 5 6 7 8 9 10; do
              if curl -fsS --max-time 5 "${HEALTH_URL}${path}"; then echo; ok=1; break; fi
              sleep 3
            done
            [ "$ok" -eq 1 ] || { echo "Health check failed: ${path}"; exit 1; }
          done
        '''
      }
    }
  }

  post {
    success {
      echo "ScoutOps ${env.SCOUTOPS_VERSION} built, deployed and healthy."
    }
    failure {
      echo 'Pipeline FAILED - see the first red stage above. Nothing after a failed stage was executed.'
      sh 'docker logs --tail=100 scoutops-app || true'
    }
    always {
      sh 'rm -f .env || true'
      sh 'docker image prune -f || true'
    }
  }
}
