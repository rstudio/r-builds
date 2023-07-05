PLATFORMS := ubuntu-1804 ubuntu-2004 ubuntu-2204 debian-10 debian-11 debian-12 centos-7 centos-8 rhel-9 opensuse-153 opensuse-154
SLS_BINARY ?= ./node_modules/serverless/bin/serverless.js

deps:
	npm install

docker-build:
	@cd builder && docker-compose build --parallel

AWS_ACCOUNT_ID:=$(shell aws sts get-caller-identity --output text --query 'Account')
AWS_REGION := us-east-1
docker-push: ecr-login docker-build
	@for platform in $(PLATFORMS) ; do \
		docker tag r-builds:$$platform $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/r-builds:$$platform; \
		docker push $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/r-builds:$$platform; \
	done

docker-down:
	@cd builder && docker-compose down

docker-build-r: docker-build
	@cd builder && docker-compose up

docker-shell-r-env:
	@cd builder && docker-compose run --entrypoint /bin/bash ubuntu-2004

ecr-login:
	(aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com)

push-serverless-custom-file:
	aws s3 cp serverless-custom.yml s3://rstudio-devops/r-builds/serverless-custom.yml

# Temporarily patch serverless-custom.yml to not Dockerize pip and disable
# serverless-python-requirements caching. The caching does not work in Jenkins
# by default because the cache directory is resolved to a relative ".cache"
# directory, rather than an absolute directory, which breaks the plugin.
# The cache directory must either be an absolute path (optionally specified
# via cacheLocation: /path/to/cache), or caching must be disabled for the plugin
# to work. We disable caching completely to avoid all sorts of future issues.
# The cache directory is based on $HOME, which is set to "." when running
# Docker images in Jenkins for some reason.
fetch-serverless-custom-file:
	aws s3 cp s3://rstudio-devops/r-builds/serverless-custom.yml .
	sed -i 's|dockerizePip: true|dockerizePip: false\n  useStaticCache: false\n  useDownloadCache: false|' serverless-custom.yml

rebuild-all: deps fetch-serverless-custom-file
	$(SLS_BINARY) invoke stepf -n rBuilds -d '{"force": true}'

serverless-deploy.%: deps fetch-serverless-custom-file
	$(SLS_BINARY) deploy --stage $* --verbose

# Package the service only, for debugging.
# Requires deps and fetch-serverless-custom-file to be run first.
serverless-package:
	$(SLS_BINARY) package --verbose

define GEN_TARGETS
docker-build-$(platform):
	@cd builder && docker-compose build $(platform)

build-r-$(platform):
	@cd builder && R_VERSION=$(R_VERSION) docker-compose run --rm $(platform)

test-r-$(platform):
	@cd test && R_VERSION=$(R_VERSION) docker-compose run --rm $(platform)

bash-$(platform):
	docker run -it --rm --entrypoint /bin/bash -v $(CURDIR):/r-builds r-builds:$(platform)

.PHONY: docker-build-$(platform) build-r-$(platform) test-r-$(platform) bash-$(platform)
endef

$(foreach platform,$(PLATFORMS), \
    $(eval $(GEN_TARGETS)) \
)

print-platforms:
	@echo $(PLATFORMS)

# Helper for launching a bash session on a docker image of your choice. Defaults
# to "ubuntu:xenial".
TARGET_IMAGE?=ubuntu:xenial
bash:
	docker run --privileged=true -it --rm \
		-v $(CURDIR):/r-builds \
		-w /r-builds \
		${TARGET_IMAGE} /bin/bash

.PHONY: deps docker-build docker-push docker-down docker-build-package docker-shell-package-env ecr-login fetch-serverless-custom-file print-platforms serverless-deploy
