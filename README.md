# r-builds

This repository orchestrates tools to produce R binaries. The binaries are available as a
community resource, **they are not professionally supported by RStudio**. 
The R language is open source, please see the official documentation at https://www.r-project.org/.

These binaries are not a replacement to existing binary distributions for R.
The binaries were built with the following considerations:
- They use a minimal set of [build and runtime dependencies](builder).
- They are designed to be used side-by-side, e.g., on [RStudio Server Pro](https://docs.rstudio.com/ide/server-pro/r-versions.html#using-multiple-versions-of-r-concurrently).
- They give users a consistent option for accessing R across different Linux distributions.

These binaries have been extensively tested, and are used in production everyday
on [RStudio Cloud](https://rstudio.cloud) and
[shinyapps.io](https://shinyapps.io). Please open an issue to report a specific
bug, or ask questions on [RStudio Community](https://community.rstudio.com).

## Supported Platforms

R binaries are built for the following Linux operating systems:

- Ubuntu 18.04, 20.04, 22.04
- Debian 10, 11
- CentOS 7
- Red Hat Enterprise Linux 7, 8, 9
- openSUSE 15.3, 15.4
- SUSE Linux Enterprise 15 SP3, 15 SP4

Operating systems are supported until their vendor end-of-support dates, which
can be found on the [RStudio Platform Support](https://www.rstudio.com/about/platform-support/)
page. When an operating system has reached its end of support, builds for it
will be discontinued, but existing binaries will continue to be available.

## Quick Installation

To use our quick install script to install R, simply run the following
command. To use the quick installer, you must have root or sudo privileges,
and `curl` must be installed.

```sh
bash -c "$(curl -L https://rstd.io/r-install)"
```

## Manual Installation

### Specify R version

Define the version of R that you want to install. Available versions
of R can be found here: https://cdn.rstudio.com/r/versions.json
```bash
R_VERSION=4.1.3
```

### Download and install R
#### Ubuntu/Debian Linux

Download the deb package:
```bash
# Ubuntu 18.04
wget https://cdn.rstudio.com/r/ubuntu-1804/pkgs/r-${R_VERSION}_1_amd64.deb

# Ubuntu 20.04
wget https://cdn.rstudio.com/r/ubuntu-2004/pkgs/r-${R_VERSION}_1_amd64.deb

# Ubuntu 22.04
wget https://cdn.rstudio.com/r/ubuntu-2204/pkgs/r-${R_VERSION}_1_amd64.deb

# Debian 10
wget https://cdn.rstudio.com/r/debian-10/pkgs/r-${R_VERSION}_1_amd64.deb

# Debian 11
wget https://cdn.rstudio.com/r/debian-11/pkgs/r-${R_VERSION}_1_amd64.deb
```

Then install the package:
```bash
sudo apt-get install gdebi-core
sudo gdebi r-${R_VERSION}_1_amd64.deb
```

#### RHEL/CentOS Linux

Enable the [Extra Packages for Enterprise Linux](https://fedoraproject.org/wiki/EPEL)
repository (RHEL/CentOS 7 and RHEL 9 only):

```bash
# CentOS / RHEL 7
sudo yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm

# Rocky Linux 9 / AlmaLinux 9
sudo dnf install dnf-plugins-core
sudo dnf config-manager --set-enabled crb
sudo dnf install epel-release

# RHEL 9
sudo dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
```

> On RHEL 7, you may also need to enable the Optional repository:
> ```bash
> sudo subscription-manager repos --enable "rhel-*-optional-rpms"
>
> # If running RHEL 7 in a public cloud, such as Amazon EC2, enable the
> # Optional repository from Red Hat Update Infrastructure (RHUI) instead
> sudo yum install yum-utils
> sudo yum-config-manager --enable "rhel-*-optional-rpms"
> ```

> On RHEL 9, you may also need to enable the CodeReady Linux Builder repository:
> ```bash
> sudo subscription-manager repos --enable codeready-builder-for-rhel-9-$(arch)-rpms
> 
> # If running RHEL 9 in a public cloud, such as Amazon EC2, enable the CodeReady
> # Linux Builder repository from Red Hat Update Infrastructure (RHUI) instead
> sudo dnf install dnf-plugins-core
> sudo dnf config-manager --enable codeready-builder-for-rhel-9-*-rpms
> ```

Download the rpm package:
```bash
# CentOS / RHEL 7
wget https://cdn.rstudio.com/r/centos-7/pkgs/R-${R_VERSION}-1-1.x86_64.rpm

# RHEL 8 / Rocky Linux 8 / AlmaLinux 8
wget https://cdn.rstudio.com/r/centos-8/pkgs/R-${R_VERSION}-1-1.x86_64.rpm

# RHEL 9 / Rocky Linux 9 / AlmaLinux 9
wget https://cdn.rstudio.com/r/rhel-9/pkgs/R-${R_VERSION}-1-1.x86_64.rpm
```

Then install the package:
```bash
sudo yum install R-${R_VERSION}-1-1.x86_64.rpm
```

#### SUSE Linux

Download the rpm package:
```bash
# openSUSE 15.3 / SLES 15 SP3
wget https://cdn.rstudio.com/r/opensuse-153/pkgs/R-${R_VERSION}-1-1.x86_64.rpm

# openSUSE 15.4 / SLES 15 SP4
wget https://cdn.rstudio.com/r/opensuse-154/pkgs/R-${R_VERSION}-1-1.x86_64.rpm
```

Then install the package:
```bash
sudo zypper --no-gpg-checks install R-${R_VERSION}-1-1.x86_64.rpm
```

### Verify R installation

Test that R was successfully installed by running:
```bash
/opt/R/${R_VERSION}/bin/R --version
```

### Add R to the system path

To ensure that R is available on the system path, create symbolic links to
the version of R that you installed:

```bash
sudo ln -s /opt/R/${R_VERSION}/bin/R /usr/local/bin/R 
sudo ln -s /opt/R/${R_VERSION}/bin/Rscript /usr/local/bin/Rscript
```

### Optional post-installation steps

You may want to install additional system dependencies for R packages.
We recommend installing a TeX distribution (such as [TinyTeX](https://yihui.name/tinytex/)
or TeX Live) and Pandoc. For more information on system dependencies, see
[system requirements for R packages](https://github.com/rstudio/r-system-requirements).

If you want to install multiple versions of R on the same system, you can
repeat these steps to install a different version of R alongside existing versions.

---

# Developer Documentation

This repository orchestrates builds using a variety of tools. The
instructions below outline the components in the stack and describe how to add a
new platform or inspect an existing platform.

## Adding a new platform.

### Dockerfile

Create a `builder/Dockerfile.platform-version` (where `platform-version` is `ubuntu-2204` or `centos-7`, etc.) This file must contain four major tasks:

1. an `OS_IDENTIFIER` env with the `platform-version`.
2. a step which ensures the R source build dependencies are installed
3. The `awscli`, 1.17.10+ if installed via `pip`, for uploading tarballs to S3
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
  dockerfile: Dockerfile.debian-11
image: r-builds:debian-11
volumes:
  - ./integration/tmp:/tmp/output  # path to output tarballs
```

### Job definition

IN `serverless-resources.yml` you'll need to add a job definition that points to the ECR image.

```
rBuildsBatchJobDefinitionDebian11:
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
      Image: #{AWS::AccountId}.dkr.ecr.#{AWS::Region}.amazonaws.com/r-builds:debian-11
```

### Environment variables in the serverless.yml functions.

The serverless functions which trigger R builds need to be informed of new platforms.

1. Add a `JOB_DEFINITION_ARN_PlatformVersion` env variable with a ref to the Job definition above.
2. Append the `platform-version` to `SUPPORTED_PLATFORMS`.

```
environment:
  # snip
  JOB_DEFINITION_ARN_debian_11:
    Ref: rBuildsBatchJobDefinitionDebian11
  SUPPORTED_PLATFORMS: ubuntu-1804,debian-10,centos-7,centos-8
```

### Makefile

In order for the makefile to push these new platforms to ECR, add them to the PLATFORMS variable near the top of the Makefile

### test/docker-compose.yml

A new service in the `test/docker-compose.yml` file named according to the `platform-version` and containing the proper entries:

```yaml
  ubuntu-2204:
    image: ubuntu:jammy
    command: /r-builds/test/test-apt.sh
    environment:
      - OS_IDENTIFIER=ubuntu-2204
      - R_VERSION=${R_VERSION}
    volumes:
      - ../:/r-builds
```

### Submit a Pull Request

Once you've followed the steps above, submit a pull request. On successful merge, builds for this platform will begin to be available from the CDN.

## "Break Glass"

Periodically, someone with access to these resources may need to re-trigger every R version/platform combination. This quite easy with the `serverless` tool installed.

```bash
# Rebuild all R versions
serverless invoke stepf -n rBuilds -d '{"force": true}'

# Rebuild specific R versions
serverless invoke stepf -n rBuilds -d '{"force": true, "versions": ["3.6.3", "4.0.2"]}'
```

## Testing

Tests are automatically run on each push that changes a file in `builder/`, `test/`, or the `Makefile`.
These tests validate that R was correctly configured, built, and packaged. By default, the tests run
for the last 5 minor R versions on each platform.

To run the tests manually, you can navigate to the [GitHub Actions workflow page](https://github.com/rstudio/r-builds/actions/workflows/test.yml)
and use "Run workflow" to run the tests from a custom branch, list of platforms, and list of R versions.

To skip the tests, add `[skip ci]` to your commit message. See [Skipping workflow runs](https://docs.github.com/en/actions/managing-workflow-runs/skipping-workflow-runs)
for more information.

To test the R builds locally, you can use the `build-r-$PLATFORM` and `test-r-$PLATFORM`
targets to build R and run the tests. The tests use the quick install script to install R,
using a locally built R if present, or otherwise a build from the CDN.

```bash
# Build R 4.1.3 for Ubuntu 22
R_VERSION=4.1.3 make build-r-ubuntu-2204

# Test R 4.1.3 for Ubuntu 22
R_VERSION=4.1.3 make test-r-ubuntu-2204
```

Alternatively, you can build an image using the `docker-build-$PLATFORM`
target, launch a bash session within a container using the `bash-$PLATFORM` target,
and interactively run the build script:

```bash
# Build the image for Ubuntu 22
make docker-build-ubuntu-2204

# Launch a bash session for Ubuntu 22
make bash-ubuntu-2204

# Build R 4.1.3
R_VERSION=4.1.3 ./build.sh

# Build R devel with parallel execution to speed up the build
MAKEFLAGS=-j4 R_VERSION=devel ./build.sh

# Build a prerelease version of R (e.g., alpha or beta)
R_VERSION=rc R_TARBALL_URL=https://cran.r-project.org/src/base-prerelease/R-latest.tar.gz ./build.sh
```
