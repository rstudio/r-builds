PLATFORMS := ubuntu-2004 ubuntu-2204 ubuntu-2404 debian-12 centos-7 centos-8 rhel-9 opensuse-156 fedora-40 fedora-41 fedora-42
SLS_BINARY ?= ./node_modules/serverless/bin/serverless.js

deps:
	npm install

docker-build:
	@cd builder && docker compose build --parallel

AWS_ACCOUNT_ID:=$(shell aws sts get-caller-identity --output text --query 'Account')
AWS_REGION := us-east-1
docker-push: ecr-login docker-build
	@for platform in $(PLATFORMS) ; do \
		docker tag r-builds:$$platform $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/r-builds:$$platform; \
		docker push $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/r-builds:$$platform; \
	done

docker-down:
	@cd builder && docker compose down

docker-build-r: docker-build
	@cd builder && docker compose up

docker-shell-r-env:
	@cd builder && docker compose run --entrypoint /bin/bash ubuntu-2004

ecr-login:
	(aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com)

push-serverless-custom-file:
	aws s3 cp serverless-custom.yml s3://rstudio-devops/r-builds/serverless-custom.yml

fetch-serverless-custom-file:
	aws s3 cp s3://rstudio-devops/r-builds/serverless-custom.yml .

rebuild-all: deps fetch-serverless-custom-file
	$(SLS_BINARY) invoke stepf -n rBuilds -d '{"force": true}'

serverless-deploy.%: deps fetch-serverless-custom-file
	$(SLS_BINARY) deploy --stage $* --verbose

define GEN_TARGETS
docker-build-$(platform):
	@cd builder && PLATFORM_ARCH=$(PLATFORM_ARCH) docker compose build $(platform)

build-r-$(platform):
	cd builder && R_VERSION=$(R_VERSION) PLATFORM_ARCH=$(PLATFORM_ARCH) docker compose run --rm $(platform)

test-r-$(platform):
	@cd test && R_VERSION=$(R_VERSION) PLATFORM_ARCH=$(PLATFORM_ARCH) docker compose run --rm $(platform)

# TODO: rename arm64 tarball differently

OUTPUT_DIR = builder/integration/tmp

# publish-r-$(platform):
# 	baseName="r/${OS_IDENTIFIER}"
# 	if [ -n "$S3_BUCKET" ] && [ "$S3_BUCKET" != "" ]; then
#     echo "Storing artifact on s3: ${S3_BUCKET}, tarball: ${TARBALL_NAME}"
#     aws s3 cp /tmp/${TARBALL_NAME} s3://${S3_BUCKET}/${S3_BUCKET_PREFIX}${baseName}/${TARBALL_NAME}
#     # check if PKG_FILE has been set by a packager script and act accordingly
#     if [ -n "$PKG_FILE" ] && [ "$PKG_FILE" != "" ]; then
#       if [ -f "$PKG_FILE" ]; then
# 	aws s3 cp ${PKG_FILE} s3://${S3_BUCKET}/${S3_BUCKET_PREFIX}${baseName}/pkgs/$(basename ${PKG_FILE})
# 	@cd test && R_VERSION=$(R_VERSION) docker compose run --rm $(platform) publish

bash-$(platform):
	docker run -it --rm --entrypoint /bin/bash -v $(CURDIR):/r-builds r-builds:$(platform)

.PHONY: docker-build-$(platform) build-r-$(platform) test-r-$(platform) publish-r-$(platform) bash-$(platform)
endef

$(foreach platform,$(PLATFORMS), \
    $(eval $(GEN_TARGETS)) \
)

print-platforms:
	@echo $(PLATFORMS)

# Helper for launching a bash session on a docker image of your choice. Defaults
# to "ubuntu:noble".
TARGET_IMAGE?=ubuntu:noble
bash:
	docker run --privileged=true -it --rm \
		-v $(CURDIR):/r-builds \
		-w /r-builds \
		${TARGET_IMAGE} /bin/bash

.PHONY: deps docker-build docker-push docker-down docker-build-package docker-shell-package-env ecr-login fetch-serverless-custom-file print-platforms serverless-deploy
