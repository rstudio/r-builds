PLATFORMS := ubuntu-1604 ubuntu-1804 debian-9 centos-6 centos-7 opensuse-42 opensuse-15

npm-install:
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
	@cd builder && docker-compose run --entrypoint /bin/bash ubuntu-1604

ecr-login:
	@eval $(shell aws ecr get-login --no-include-email --region $(AWS_REGION))

fetch-serverless-custom-file:
	aws s3 cp s3://rstudio-serverless/serverless/r-builds/serverless-custom.yml .

serverless-deploy: npm-install fetch-serverless-custom-file
	serverless deploy --stage dev

.PHONY: docker-build docker-push docker-down docker-build-package docker-shell-package-env ecr-login npm-install fetch-serverless-custom-file serverless-deploy
