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
- Ubuntu 16.04, 18.04, 20.04
- Debian 9, 10
- CentOS 7
- Red Hat Enterprise Linux 7, 8
- openSUSE 42.3, 15.1, 15.2, 15.3
- SUSE Linux Enterprise 12, 15 SP1, 15 SP2, 15 SP3

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
R_VERSION=3.5.3
```

### Download and install R
#### Ubuntu/Debian Linux

Download the deb package:
```bash
# Ubuntu 16.04
wget https://cdn.rstudio.com/r/ubuntu-1604/pkgs/r-${R_VERSION}_1_amd64.deb

# Ubuntu 18.04
wget https://cdn.rstudio.com/r/ubuntu-1804/pkgs/r-${R_VERSION}_1_amd64.deb

# Ubuntu 20.04
wget https://cdn.rstudio.com/r/ubuntu-2004/pkgs/r-${R_VERSION}_1_amd64.deb

# Debian 9
wget https://cdn.rstudio.com/r/debian-9/pkgs/r-${R_VERSION}_1_amd64.deb

# Debian 10
wget https://cdn.rstudio.com/r/debian-10/pkgs/r-${R_VERSION}_1_amd64.deb
```

Then install the package:
```bash
sudo apt-get install gdebi-core
sudo gdebi r-${R_VERSION}_1_amd64.deb
```

#### RHEL/CentOS Linux

Enable the [Extra Packages for Enterprise Linux](https://fedoraproject.org/wiki/EPEL)
repository (RHEL/CentOS 7 only):

```bash
# CentOS / RHEL 7
sudo yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
```

> Note that on RHEL 7, you may also need to enable the Optional repository:
> ```bash
> # For RHEL 7 users with certificate subscriptions:
> sudo subscription-manager repos --enable "rhel-*-optional-rpms"
>
> # Or alternatively, using yum:
> sudo yum install yum-utils
> sudo yum-config-manager --enable "rhel-*-optional-rpms"
> ```

Download the rpm package:
```bash
# CentOS / RHEL 7
wget https://cdn.rstudio.com/r/centos-7/pkgs/R-${R_VERSION}-1-1.x86_64.rpm

# RHEL 8
wget https://cdn.rstudio.com/r/centos-8/pkgs/R-${R_VERSION}-1-1.x86_64.rpm
```

Then install the package:
```bash
sudo yum install R-${R_VERSION}-1-1.x86_64.rpm
```

#### SUSE Linux

Enable the Python backports repository (SLES 12 only):
```bash
# SLES 12
VERSION="SLE_$(grep "^VERSION=" /etc/os-release | sed -e 's/VERSION=//' -e 's/"//g' -e 's/-/_/')"
sudo zypper --gpg-auto-import-keys addrepo https://download.opensuse.org/repositories/devel:/languages:/python:/backports/$VERSION/devel:languages:python:backports.repo
```

Download the rpm package:
```bash
# openSUSE 42.3 / SLES 12
wget https://cdn.rstudio.com/r/opensuse-42/pkgs/R-${R_VERSION}-1-1.x86_64.rpm

# openSUSE 15.1 / SLES 15 SP1
wget https://cdn.rstudio.com/r/opensuse-15/pkgs/R-${R_VERSION}-1-1.x86_64.rpm

# openSUSE 15.2 / SLES 15 SP2
wget https://cdn.rstudio.com/r/opensuse-152/pkgs/R-${R_VERSION}-1-1.x86_64.rpm

# openSUSE 15.3 / SLES 15 SP3
wget https://cdn.rstudio.com/r/opensuse-153/pkgs/R-${R_VERSION}-1-1.x86_64.rpm
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

Create a `builder/Dockerfile.platform-version` (where `platform-version` is `ubuntu-1604` or `centos-7`, etc.) This file must contain four major tasks:

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
  SUPPORTED_PLATFORMS: ubuntu-1604,ubuntu-1804,debian-9,debian-10,centos-7,centos-8,opensuse-42,opensuse-15
```

### Makefile

In order for the makefile to push these new platforms to ECR, add them to the PLATFORMS variable near the top of the Makefile

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

To test the R builds locally, you can build the images:

```bash
# Build images for all platforms
make docker-build

# Or build the image for a single platform
(cd builder && docker-compose build ubuntu-2004)
```

Then run the build script:

```bash
# Build R for all platforms
R_VERSION=4.0.5 make docker-build-r

# Build R for a single platform
(cd builder && R_VERSION=4.0.5 docker-compose up ubuntu-2004)

# Alternatively, run the build script from within a container
docker run -it --rm --entrypoint "/bin/bash" r-builds:ubuntu-2004

# Build R 4.0.5
R_VERSION=4.0.5 ./build.sh

# Build R devel
R_VERSION=devel ./build.sh

# Build a prerelease version of R (e.g., alpha or beta)
R_VERSION=rc R_TARBALL_URL=https://cran.r-project.org/src/base-prerelease/R-latest.tar.gz ./build.sh
```
