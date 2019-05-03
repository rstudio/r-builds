# r-builds

This repository orchestrates tools to produce R binaries obtainable from:
https://cdn.rstudio.com/r/versions.json. The binaries are available as a
community resource, **they are not professionally supported by RStudio**. 
The R language is open source, please see the official documentation at https://www.r-project.org/.

These binaries are not a replacement to existing binary distributions for R.
The binaries were built with the following considerations:
- They use a minimal, documented set of
  [build](https://github.com/rstudio/r-builds/tree/master/builder) and
  [runtime](https://github.com/rstudio/r-docker) dependencies.  
- They are designed to be used side-by-side, e.g., on [RStudio Server Pro]().
- They give users a consistent option for accessing R across different Linux distributions.

These binaries have been extensively tested, and are used in production everyday
on [RStudio Cloud](https://rstudio.cloud) and
[shinyapps.io](https://shinyapps.io). Please open an issue to report a specific
bug, and address questions on [RStudio
Community](https://community.rstudio.com).

## Example Usage

These binaries are designed to be copied onto a server, as opposed to installed
using a system package manager like `apt` or `yum`. This approach allows administrators
to offer multiple versions of R side-by-side. 

```
# Pre-req install runtime pre-reqs
# Then copy the desired R version from the CD

OS_IDENTIFIER=ubuntu-1804
R_VERSION=3.5.3

wget -O R-${R_VERSION}.tar.gz https://cdn.rstudio.com/r/${OS_IDENTIFIER}/R-${R_VERSION}-${OS_IDENTIFIER}.tar.gz 
mkdir -p /opt/R 
tar zx -C /opt/R -f ./R-${R_VERSION}.tar.gz 
rm R-${R_VERSION}.tar.gz

# execute R from this directory
/opt/R/${R_VERSION}/bin/R -e 'capabilities()'

# optionally add this version to the path
PATH=/opt/R/${R_VERSION}/bin:${PATH}

# OR optionally link the binaries to /usr
ln -s /opt/R/${R_VERSION}/bin/R /usr/bin/R 
ln -s /opt/R/${R_VERSION}/bin/Rscript /usr/bin/Rscript
ln -s /opt/R/${R_VERSION}/lib/R /usr/lib/R 
```

Please see [r-docker](https://github.com/rstudio/r-docker) and
[r-system-requirements](https://github.com/rstudio/r-system-requirements) for
more information on using these binaries. The `r-docker` repository documents
required runtime system dependencies and provides users with docker images
containing these dependencies. The `r-system-requirements` repository contains
information on the additional system dependencies that may be required to
install and use R packages.

---

# Developer Documentation

This repository orchestrates builds using a variety of tools built. The
instructions below outline the components in the stack and describe how to add a
new platform or inspect an existing platform.

## Adding a new platform.

### Dockerfile

Create a `builder/Dockerfile.platform-version` (where `platform-version` is `ubuntu-1604` or `centos-74`, etc.) This file must contain four major tasks:

1. an `OS_IDENTIFIER` env with the `platform-version`.
2. a step which ensures the R source build dependencies are installed
3. The `awscli`, most likely installed via `pip` for uploading tarballs to S3
4. `COPY` and `ENTRYPOINT` for the `build.sh` file in `builder/`.

### docker-compose.yml

A new service in the docker-compose file named according to the `platform-version` and containing the proper entries:

```
command: ./build.sh
environment:
  - R_VERSION=${R_VERSION} # for testing out R builds locally
  - LOCAL_STORE=/tmp/output # ensures that output tarballs are persisted locally
build:
  context: .
  dockerfile: Dockerfile.debian-9
image: r-builds:debian-9
volumes:
  - ./integration/tmp:/tmp/output  # path to output tarballs
```

### Job definition

IN `serverless-resources.yml` you'll need to add a job definition that points to the ECR image.

```
rBuildsBatchJobDefinitionDebian9:
  Type: AWS::Batch::JobDefinition
  Properties:
    Type: container
    ContainerProperties:
      Command:
        - ./build.sh
      Vcpus: 4
      Memory: 4096
      JobRoleArn:
        "Fn::GetAtt": [ rBuildsEcsTaskIamRole, Arn ]
      Image: #{AWS::AccountId}.dkr.ecr.#{AWS::Region}.amazonaws.com/r-builds:debian-9
```

### Environment variables in the serverless.yml functions.

The serverless functions which trigger R builds need to be informed of new platforms.

1. Add a `JOB_DEFINITION_ARN_PlatformVersion` env variable with a ref to the Job definition above.
2. Append the `platform-version` to `SUPPORTED_PLATFORMS`.

```
environment:
  # snip
  JOB_DEFINITION_ARN_debian_9:
    Ref: rBuildsBatchJobDefinitionDebian9
  SUPPORTED_PLATFORMS: ubuntu-1604,ubuntu-1804,debian-9
```

### Makefile

In order for the makefile to push these new platforms to ECR, add them to the PLATFORMS variable near the top of the Makefile

### Submit a Pull Request

Once you've followed the steps above, submit a pull request. On successful merge, builds for this platform will begin to be available from the CDN.

## "Break Glass"

Periodically, someone with access to these resources may need to re-trigger every R version/platform combination. This quite easy with the `serverless` tool installed.

```
serverless invoke stepf -n rBuilds -d '{"force": true}'
```
