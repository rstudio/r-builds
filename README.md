# r-builds

This repository orchestrates tools to produce R binaries. The binaries are available as a
community resource, **they are not professionally supported by Posit**. 
The R language is open source, please see the official documentation at https://www.r-project.org/.

These binaries are not a replacement to existing binary distributions for R.
The binaries were built with the following considerations:
- They use a minimal set of [build and runtime dependencies](builder).
- They are designed to be used side-by-side, e.g., on [Posit Workbench](https://docs.posit.co/ide/server-pro/r/using_multiple_versions_of_r.html).
- They give users a consistent option for accessing R across different Linux distributions.

These binaries have been extensively tested, and are used in production everyday
on [Posit Cloud](https://posit.cloud) and
[shinyapps.io](https://shinyapps.io). Please open an issue to report a specific
bug, or ask questions on [Posit Community](https://forum.posit.co/).

## Supported Platforms

R binaries are built for the following Linux operating systems:

- Ubuntu 20.04, 22.04, 24.04
- Debian 12
- CentOS 7
- Red Hat Enterprise Linux 7, 8, 9
- openSUSE 15.6
- SUSE Linux Enterprise 15 SP6
- Fedora 40, 41, 42

Operating systems are supported until their vendor end-of-support dates, which
can be found on the [Posit Platform Support](https://posit.co/about/platform-support/)
page. When an operating system has reached its end of support, builds for it
will be discontinued, but existing binaries will continue to be available.

## Supported R Versions

R binaries are primarily supported for the current R version and previous four minor versions of R.
Older R versions down to R 3.0.0 are also built when possible, but support for older R versions is best effort and not guaranteed. 

R versions 4.0.0 through 4.3.3 have been patched for [CVE-2024-27322](https://nvd.nist.gov/vuln/detail/cve-2024-27322). See [#218](https://github.com/rstudio/r-builds/issues/218) for more details.

## Supported Architectures

R binaries are built for x86_64/amd64 and aarch64/arm64.

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
of R can be found here: https://cdn.posit.co/r/versions.json
```bash
R_VERSION=4.4.3
```

### Download and install R
#### Ubuntu/Debian Linux

Download the deb package:
```bash
# Ubuntu 20.04
curl -O https://cdn.posit.co/r/ubuntu-2004/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb

# Ubuntu 22.04
curl -O https://cdn.posit.co/r/ubuntu-2204/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb

# Ubuntu 24.04
curl -O https://cdn.posit.co/r/ubuntu-2404/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb

# Debian 12
curl -O https://cdn.posit.co/r/debian-12/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb
```

Then install the package:
```bash
sudo apt-get install ./r-${R_VERSION}_1_$(dpkg --print-architecture).deb
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
curl -O https://cdn.posit.co/r/centos-7/pkgs/R-${R_VERSION}-1-1.$(arch).rpm

# RHEL 8 / Rocky Linux 8 / AlmaLinux 8
curl -O https://cdn.posit.co/r/centos-8/pkgs/R-${R_VERSION}-1-1.$(arch).rpm

# RHEL 9 / Rocky Linux 9 / AlmaLinux 9
curl -O https://cdn.posit.co/r/rhel-9/pkgs/R-${R_VERSION}-1-1.$(arch).rpm
```

Then install the package:
```bash
sudo yum install R-${R_VERSION}-1-1.$(arch).rpm
```

#### SUSE Linux

Download the rpm package:
```bash
# openSUSE 15.6 / SLES 15 SP6
curl -O https://cdn.posit.co/r/opensuse-156/pkgs/R-${R_VERSION}-1-1.$(arch).rpm
```

Then install the package:
```bash
sudo zypper --no-gpg-checks install R-${R_VERSION}-1-1.$(arch).rpm
```

#### Fedora Linux

Download the rpm package:
```bash
# Fedora 40
curl -O https://cdn.posit.co/r/fedora-40/pkgs/R-${R_VERSION}-1-1.$(arch).rpm

# Fedora 41
curl -O https://cdn.posit.co/r/fedora-41/pkgs/R-${R_VERSION}-1-1.$(arch).rpm

# Fedora 42
curl -O https://cdn.posit.co/r/fedora-42/pkgs/R-${R_VERSION}-1-1.$(arch).rpm
```

Then install the package:
```bash
sudo dnf install R-${R_VERSION}-1-1.$(arch).rpm
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

## Building from source

To build the R binaries from source, you will need to have [Git](https://git-scm.com/),
[Docker](https://docs.docker.com/get-docker/), and `make` installed.

First, clone the Git repository locally and navigate to it.

```bash
git clone https://github.com/rstudio/R-builds
cd R-builds
```

Then, run the `build-r-$PLATFORM` Make target with the `R_VERSION` environment variable
set to your desired R version, where `$PLATFORM` is one of the supported platform
identifiers, such as `ubuntu-2204` or `rhel-9`.

```bash
export PLATFORM=ubuntu-2204
export R_VERSION=4.5.0

make build-r-$PLATFORM
```

The built DEB or RPM package will be available in the `builder/integration/tmp/$PLATFORM`
directory.

```bash
$ ls builder/integration/tmp/$PLATFORM
r-4.5.0_1_amd64.deb
```

### Custom installation path

R is installed to `/opt/R/${R_VERSION}` by default. If you want to customize the
installation path, set the optional `R_INSTALL_PATH` environment variable to a
custom location such as `/opt/custom/R-4.5.0`.

```bash
export PLATFORM=rhel-9
export R_VERSION=4.5.0
export R_INSTALL_PATH=/opt/custom/R-4.5.0

make build-r-$PLATFORM
```

## Submitting pull requests

For significant changes to the R builds, such as adding a new platform or updating existing builds,
include any relevant testing notes and changes that may affect existing users, such as system dependency changes.

On successful merge, the changes will be automatically deployed to the staging environment.

A project maintainer can then trigger the builds in staging to test the changes, and then in production
when the changes have been verified.

## Adding a new platform.

### R configuration

- Builds should use OpenBLAS and align their BLAS/LAPACK configuration with the default distribution of R when possible,
  for maximum compatibility of binary R packages across R distributions. For example, Ubuntu/Debian should be configured
  to use external BLAS, RHEL 9+ should use FlexiBLAS (to match EPEL), and SUSE should use shared BLAS. The BLAS/LAPACK
  library should be swappable at runtime when possible.
- DEB/RPM packages should include the minimum set of dependencies when possible. Different R versions may have different
  dependencies, so packaging scripts may conditionally add dependencies based on the R version.

### README

1. Add the new platform to the `Supported Platforms` list.
2. Add DEB or RPM package download instructions for the new platform.

### Dockerfile

Create a `builder/Dockerfile.platform-version` (where `platform-version` is `ubuntu-2204` or `centos-7`, etc.) This file must contain four major tasks:

1. an `OS_IDENTIFIER` env with the `platform-version`.
2. a step which ensures the R source build dependencies are installed
3. The `awscli` for uploading packages and tarballs to S3
4. `COPY` for the packaging script (`builder/package.platform-version`) to `/package.sh`
5. `COPY` and `ENTRYPOINT` for the `build.sh` file in `builder/`.

### Packaging script

Create a `builder/package.platform-version` script (where `platform-version` is `ubuntu-2204` or `centos-7`, etc.). 

### docker-compose.yml

A new service in the docker-compose file named according to the `platform-version` and containing the proper entries:

```yaml
ubuntu-2404:
  command: ./build.sh
  environment:
    - R_VERSION=${R_VERSION}  # for testing out R builds locally
    - R_INSTALL_PATH=${R_INSTALL_PATH}  # custom installation path
    - LOCAL_STORE=/tmp/output  # ensures that output tarballs are persisted locally
  build:
    context: .
    dockerfile: Dockerfile.ubuntu-2404
  image: r-builds:ubuntu-2404
  volumes:
    - ./integration/tmp:/tmp/output  # path to output tarballs
  platform: ${PLATFORM_ARCH}  # for testing other architectures via emulation
```

### Makefile

Add the new platform to the `PLATFORMS` variable near the top of the Makefile.

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
    platform: ${PLATFORM_ARCH}
```

### Quick install script

Update the quick install script at [`install.sh`](install.sh), if necessary, to support the new platform.

Once you've followed the steps above, submit a pull request.

## R builds tarballs

In addition to the DEB and RPM packages, R builds also publishes tarballs of the binaries at:

- x86_64: `https://cdn.posit.co/r/${OS_IDENTIFIER}/R-${R_VERSION}-${OS_IDENTIFIER}.tar.gz`
- arm64: `https://cdn.posit.co/r/${OS_IDENTIFIER}/R-${R_VERSION}-${OS_IDENTIFIER}-arm64.tar.gz`

These may be used with a manual installation of R's system dependencies. System dependencies will differ between R versions,
so inspect the corresponding DEB or RPM package for the list of system dependencies.

## "Break Glass" and scheduled builds

The [Check for new R versions](https://github.com/rstudio/r-builds/actions/workflows/check-r-versions.yml) workflow
checks for new R versions hourly and automatically builds and publishes them.

The [Daily R-devel and R-next builds](https://github.com/rstudio/r-builds/actions/workflows/devel-daily.yml) workflow
builds and publishes R-devel and R-next each day.

The [R builds](https://github.com/rstudio/r-builds/actions/workflows/build.yml) workflow
tests building the R binaries and optionally publishes them. Builds are not automatically published upon merging to `main`.

After making any changes to R-builds, this workflow may be run manually to test the changes in `staging` first. Then,
the workflow can be rerun for `production` to build new binaries or rebuild existing binaries.

## Testing

Tests are automatically run on each push.
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
# Build R 4.5.0 for Ubuntu 22
R_VERSION=4.5.0 make build-r-ubuntu-2204

# Test R 4.5.0 for Ubuntu 22
R_VERSION=4.5.0 make test-r-ubuntu-2204
```

Alternatively, you can build an image using the `docker-build-$PLATFORM`
target, launch a bash session within a container using the `bash-$PLATFORM` target,
and interactively run the build script:

```bash
# Build the image for Ubuntu 22
make docker-build-ubuntu-2204

# Launch a bash session for Ubuntu 22
make bash-ubuntu-2204

# Build R 4.5.0
R_VERSION=4.5.0 ./build.sh

# Build R devel with parallel execution to speed up the build
MAKEFLAGS=-j4 R_VERSION=devel ./build.sh

# Build a prerelease version of R (e.g., alpha or beta)
R_VERSION=rc R_TARBALL_URL=https://cran.r-project.org/src/base-prerelease/R-latest.tar.gz ./build.sh
```

Builds default to the current host architecture by default. If you would like to test a different
architecture via emulation in Docker, set `PLATFORM_ARCH` to a valid Docker `--platform` flag:

```bash
# Build R 4.5.0 for Ubuntu 22, ARM64
R_VERSION=4.5.0 PLATFORM_ARCH=linux/arm64 make build-r-ubuntu-2204

# Test R 4.5.0 for Ubuntu 22, ARM64
R_VERSION=4.5.0 PLATFORM_ARCH=linux/arm64 make test-r-ubuntu-2204
```
