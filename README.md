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

- Ubuntu 20.04, 22.04, 24.04, 26.04
- Debian 12, 13
- CentOS 7
- Red Hat Enterprise Linux 7, 8, 9, 10
- openSUSE 15.6, 16.0
- SUSE Linux Enterprise 15 SP6
- Fedora 42, 43

Operating systems are supported until their vendor end-of-support dates, which
can be found on the [Posit Platform Support](https://posit.co/about/platform-support/)
page. When an operating system has reached its end of support, builds for it
will be discontinued, but existing binaries will continue to be available.

### Portable builds (experimental)

Portable R builds are also available that bundle most library dependencies
and are relocatable to any install path. The Linux variants work across
distributions without distro-specific packages; the macOS and Windows
variants post-process the official CRAN binaries so they can be extracted
anywhere instead of installed system-wide.

- **manylinux** - any Linux distro with glibc >= 2.34 (RHEL 9+, Ubuntu 22.04+,
  Debian 12+, Amazon Linux 2023+, Arch Linux, etc.)
- **musllinux** - Alpine Linux 3.20+ and other musl-based distros
- **macOS** - arm64 (Apple Silicon) and x86_64 (Intel; also runs under
  Rosetta 2), R 4.1.0+
- **Windows** - x86_64, R 3.6.3+

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

# Ubuntu 26.04
curl -O https://cdn.posit.co/r/ubuntu-2604/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb

# Debian 12
curl -O https://cdn.posit.co/r/debian-12/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb

# Debian 13
curl -O https://cdn.posit.co/r/debian-13/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb
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

# RHEL 10 / Rocky Linux 10 / AlmaLinux 10
curl -O https://cdn.posit.co/r/rhel-10/pkgs/R-${R_VERSION}-1-1.$(arch).rpm
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

# openSUSE 16.0
curl -O https://cdn.posit.co/r/opensuse-160/pkgs/R-${R_VERSION}-1-1.$(arch).rpm
```

Then install the package:
```bash
sudo zypper --no-gpg-checks install R-${R_VERSION}-1-1.$(arch).rpm
```

#### Fedora Linux

Download the rpm package:
```bash
# Fedora 42
curl -O https://cdn.posit.co/r/fedora-42/pkgs/R-${R_VERSION}-1-1.$(arch).rpm

# Fedora 43
curl -O https://cdn.posit.co/r/fedora-43/pkgs/R-${R_VERSION}-1-1.$(arch).rpm
```

Then install the package:
```bash
sudo dnf install R-${R_VERSION}-1-1.$(arch).rpm
```

#### Portable (manylinux) - any Linux distro with glibc >= 2.34

Portable builds are available that work across Linux distributions without
distro-specific packages. Most library dependencies are bundled; R auto-detects
its install location so it can be extracted to any path.

These portable builds are useful for Linux distributions that don't have
dedicated r-builds packages, such as:

- Amazon Linux 2023
- Arch Linux
- Other glibc-based distros not in the supported platform list

Three package formats are available: **tar.gz** (universal), **DEB**
(Debian/Ubuntu-based distros), and **RPM** (RHEL/Fedora/SUSE-based distros).
The DEB and RPM packages automatically install `ca-certificates` and `fontconfig`
as dependencies, and install R to `/opt/R/<version>/`. On distros that don't use
DEB or RPM, use the tarball. The tarball is also the right choice if you need R
installed to a custom path or without root access, since it can be extracted
anywhere (R auto-detects its location at runtime).

The portable builds require glibc >= 2.34 (RHEL 9+, Ubuntu 22.04+, Debian 12+,
Amazon Linux 2023+, Arch Linux, etc.). RHEL 8 and Ubuntu 20.04 are not supported;
use the distro-specific packages above instead.

Portable builds bundle most shared library dependencies (including OpenSSL and
libcurl). Unlike distro-specific builds, updating system packages on the host
does not update the bundled copies; users must reinstall R to receive updates
for bundled libraries. Each build includes a CycloneDX SBOM at
`$R_HOME/sbom.cdx.json` listing all bundled libraries and their source packages.
See the [portable-r README](builder/portable-r/README.md) for details.

##### Install via DEB package (Debian/Ubuntu and derivatives)

```bash
curl -O https://cdn.posit.co/r/manylinux_2_34/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb
sudo apt-get install -y ./r-${R_VERSION}_1_$(dpkg --print-architecture).deb
```

##### Install via RPM package (RHEL/Fedora/Rocky/Amazon Linux/SUSE)

```bash
curl -O https://cdn.posit.co/r/manylinux_2_34/pkgs/R-${R_VERSION}-1-1.$(arch).rpm
sudo dnf install -y R-${R_VERSION}-1-1.$(arch).rpm       # RHEL/Fedora/Rocky/Amazon Linux
sudo zypper --no-gpg-checks install R-${R_VERSION}-1-1.$(arch).rpm  # openSUSE/SLES
```

##### Install via tarball (any Linux distro)

Download and extract:
```bash
# x86_64
curl -O https://cdn.posit.co/r/manylinux_2_34/R-${R_VERSION}-manylinux_2_34.tar.gz

# arm64
curl -O https://cdn.posit.co/r/manylinux_2_34/R-${R_VERSION}-manylinux_2_34-arm64.tar.gz

sudo mkdir -p /opt/R
sudo tar xzf R-${R_VERSION}-manylinux_2_34*.tar.gz -C /opt/R

# Or install to a user-writable directory (no root required):
mkdir -p ~/R
tar xzf R-${R_VERSION}-manylinux_2_34*.tar.gz -C ~/R
~/R/${R_VERSION}/bin/R --version
```

Install system dependencies (only needed for tarballs; DEB/RPM handle this automatically):
```bash
# SSL/TLS certificates (for HTTPS, e.g. install.packages)
# Ubuntu/Debian
sudo apt-get install -y ca-certificates
# RHEL/Fedora/Rocky/Amazon Linux
sudo dnf install -y ca-certificates which
# openSUSE/SLES
sudo zypper install -y ca-certificates which
# Arch Linux
sudo pacman -S ca-certificates which

# Font configuration and fonts (for plotting with cairo graphics devices)
# Ubuntu/Debian
sudo apt-get install -y fontconfig
# RHEL/Fedora/Rocky/Amazon Linux
sudo dnf install -y fontconfig
# openSUSE/SLES (fontconfig does not pull in fonts automatically)
sudo zypper install -y fontconfig dejavu-fonts
# Arch Linux
sudo pacman -S fontconfig
```

Optional - for installing R packages from source (`R CMD INSTALL`):
```bash
# Ubuntu/Debian
sudo apt-get install -y build-essential gfortran \
  libpcre2-dev liblzma-dev libbz2-dev zlib1g-dev libicu-dev
  # For R 3.x, also install: libpcre3-dev

# RHEL/Fedora/Rocky/Amazon Linux
sudo dnf install -y gcc gcc-c++ gcc-gfortran make \
  pcre2-devel xz-devel bzip2-devel zlib-devel libicu-devel
  # For R 3.x, also install: pcre-devel

# openSUSE/SLES
sudo zypper install -y gcc gcc-c++ gcc-fortran make \
  pcre2-devel xz-devel libbz2-devel zlib-devel libicu-devel
  # For R 3.x, also install: pcre-devel

# Arch Linux
sudo pacman -S base-devel gcc-fortran pcre2 xz bzip2 zlib icu
```

#### Portable (musllinux) - Alpine Linux and musl-based distros

Portable builds are available for Linux distributions that use musl libc
instead of glibc, such as Alpine Linux. Most library dependencies are bundled,
and R auto-detects its install location so it can be extracted to any path.

These builds require musl >= 1.2 (Alpine 3.20+, Void Linux musl, etc.).

Two package formats are available: **APK** (Alpine Linux) and **tar.gz**
(universal). The APK package automatically installs `ca-certificates`,
`fontconfig`, and `ttf-dejavu` as dependencies, and installs R to
`/opt/R/<version>/`. On non-Alpine musl distros, use the tarball.

##### Install via APK package (Alpine Linux)

```bash
curl -O https://cdn.posit.co/r/musllinux_1_2/pkgs/r-${R_VERSION}_1_$(apk --print-arch).apk
sudo apk add --allow-untrusted ./r-${R_VERSION}_1_$(apk --print-arch).apk
```

##### Install via tarball

Download and extract:
```bash
# x86_64
curl -O https://cdn.posit.co/r/musllinux_1_2/R-${R_VERSION}-musllinux_1_2.tar.gz

# arm64
curl -O https://cdn.posit.co/r/musllinux_1_2/R-${R_VERSION}-musllinux_1_2-arm64.tar.gz

sudo mkdir -p /opt/R
sudo tar xzf R-${R_VERSION}-musllinux_1_2*.tar.gz -C /opt/R

# Or install to a user-writable directory (no root required):
mkdir -p ~/R
tar xzf R-${R_VERSION}-musllinux_1_2*.tar.gz -C ~/R
~/R/${R_VERSION}/bin/R --version
```

Install system dependencies (only needed for tarballs; APK handles this automatically):
```bash
# Runtime dependencies
sudo apk add --no-cache ca-certificates fontconfig ttf-dejavu

# Optional: build tools for installing R packages from source
sudo apk add --no-cache \
  gcc g++ gfortran make \
  pcre2-dev xz-dev bzip2-dev zlib-dev zstd-dev icu-dev
```


#### Portable macOS (experimental)

Portable, relocatable macOS R builds are available for arm64 (Apple Silicon)
and x86_64 (Intel). These are post-processed CRAN binaries: the official
`.pkg` installer is downloaded, extracted without installing, and patched so
all hardcoded `/Library/Frameworks/R.framework/...` paths in Mach-O load
commands and config files are rewritten to `@rpath`/`@loader_path`
references. The result is a tarball that can be extracted to any directory
and run from there — no admin rights, no Gatekeeper installer prompts, no
side effects on the system R installation.

These macOS builds are available for R 4.1.0 and later. R 4.0.x and R 3.x
are not supported because CRAN does not host a macOS `.pkg` installer for
those versions on either the main mirror or the CRAN archive. Use the
official CRAN installer for those versions instead.

Bundled libraries (Tcl/Tk, gfortran runtime, etc.) come from the CRAN `.pkg`,
so behavior matches CRAN's official binary R for macOS. Each `.so` and
`.dylib` is signed (ad-hoc on staging, Developer ID + notarized on
production); when the production secrets are configured, downloaded tarballs
pass Gatekeeper without quarantine. See [`macos/README.md`](macos/README.md)
for the full technical breakdown.

##### Install via tarball

```bash
R_VERSION=4.4.3

# arm64 (Apple Silicon)
curl -O https://cdn.posit.co/r/macos/R-${R_VERSION}-macos-arm64.tar.gz
mkdir -p ~/R
tar xzf R-${R_VERSION}-macos-arm64.tar.gz -C ~/R
~/R/R-${R_VERSION}/bin/R --version

# x86_64 (Intel; also runs under Rosetta 2 on Apple Silicon)
curl -O https://cdn.posit.co/r/macos/R-${R_VERSION}-macos.tar.gz
mkdir -p ~/R
tar xzf R-${R_VERSION}-macos.tar.gz -C ~/R
~/R/R-${R_VERSION}/bin/R --version
```

If you downloaded an unsigned/un-notarized tarball with `curl`, macOS
attaches a quarantine attribute on extracted files. Strip it once with:

```bash
xattr -dr com.apple.quarantine ~/R/R-${R_VERSION}
```

Optional — for installing R packages that require compilation from source,
install the Xcode Command Line Tools:

```bash
xcode-select --install
```

**Using the portable R inside Positron** — Positron's R discovery requires
each R installation to live at the canonical
`/Library/Frameworks/R.framework/Versions/<ver>-<arch>/Resources` path on
disk (or be reachable via that path through a symlink). For the portable R
to appear in Positron's interpreter picker, either install the tarball
directly at that path, or symlink it once after extraction:

```bash
ARCH=arm64       # or x86_64
RVER_MM=4.4      # major.minor of the R you extracted

sudo mkdir -p /Library/Frameworks/R.framework/Versions/${RVER_MM}-${ARCH}
sudo ln -s ~/R/R-${R_VERSION} \
  /Library/Frameworks/R.framework/Versions/${RVER_MM}-${ARCH}/Resources
```

Don't run this on a host that already has a real R install at that
version-arch — it'll shadow the framework `Resources` for that version.
RStudio and command-line use don't need this step.

The architectures of Positron and the R install must match: Positron's R
kernel loads `libR.dylib` in-process, and macOS dyld cannot `dlopen` a
dylib of a different architecture. On Apple Silicon, install x86_64
Positron alongside arm64 if you need to use the x86_64 portable R build,
or stick with the arm64 build. RStudio does not have this constraint
because it launches R as a subprocess. See [`macos/README.md`](macos/README.md)
for the technical reasoning.

#### Portable Windows (experimental)

Portable, relocatable Windows R builds are available for x86_64. The
official CRAN `.exe` installer is downloaded and extracted with
[`innoextract`](https://github.com/dscharrer/innoextract) (with a
`/VERYSILENT /CURRENTUSER` silent-install fallback if `innoextract` is
unavailable), so no admin rights, no registry changes, and no side effects
on the system R installation. Windows R is already largely self-contained
(all DLLs bundled, paths largely relative), so unlike macOS no Mach-O
patching pipeline is needed — extraction + a portable site-library and
default repo configuration is all that's required.

These Windows builds are available for R 3.6.3 and later, with R 3.6.3
included as a long-term compatibility anchor (matching the existing Linux
builds). See [`windows/README.md`](windows/README.md) for the full technical
breakdown.

##### Install via zip

```powershell
$RVersion = "4.4.3"

Invoke-WebRequest -Uri "https://cdn.posit.co/r/windows/R-$RVersion-windows.zip" -OutFile "R-$RVersion-windows.zip"
Expand-Archive "R-$RVersion-windows.zip" -DestinationPath C:\
& "C:\R-$RVersion\bin\R.exe" --version
```

Optional — for installing R packages that require compilation from source,
install [Rtools](https://cran.r-project.org/bin/windows/Rtools/) (the
version that matches your R minor version, e.g. Rtools 4.4 for R 4.4.x).

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

On successful merge, a project maintainer can then trigger the builds in staging to test the changes, and then in production
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
3. `COPY` for the packaging script (`builder/package.platform-version`) to `/package.sh`
4. `COPY` and `ENTRYPOINT` for the `build.sh` file in `builder/`.

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
