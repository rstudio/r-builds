PLATFORMS := ubuntu-1804 ubuntu-2004 ubuntu-2204 debian-10 debian-11 centos-7 centos-8 rhel-9 opensuse-153 opensuse-154
SLS_BINARY ?= ./node_modules/serverless/bin/serverless

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

fetch-serverless-custom-file:
	aws s3 cp s3://rstudio-devops/r-builds/serverless-custom.yml .

rebuild-all: deps fetch-serverless-custom-file
	$(SLS_BINARY) invoke stepf -n rBuilds -d '{"force": true}'

serverless-deploy.%: deps fetch-serverless-custom-file
	$(SLS_BINARY) deploy --stage $*

define GEN_TARGETS
docker-build-$(platform):
	@cd builder && docker-compose build $(platform)

build-r-$(platform):
	@cd builder && R_VERSION=$(R_VERSION) docker-compose up $(platform)

test-r-$(platform):
	@cd test && R_VERSION=$(R_VERSION) docker-compose up $(platform)

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
