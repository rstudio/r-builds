# CLAUDE.md

## Project overview

r-builds compiles R from source for Linux distros using Docker. Each platform has a Dockerfile, package script, and test configuration. Portable builds (manylinux/musllinux) add a post-build portability layer via `delocate_r.py` + patchelf.

## Key commands

```bash
# Build Docker image for a platform (required after Dockerfile or package script changes)
make docker-build-<platform>

# Build R for a platform
R_VERSION=4.4.3 make build-r-<platform>

# Run integration tests
R_VERSION=4.4.3 make test-r-<platform>

# Run delocate_r.py unit tests
make unit-test

# Interactive Docker shell for debugging
docker run --rm -it -v "$PWD/builder:/builder" -v "$PWD/test:/test" \
  -e R_VERSION=4.4.3 -e OS_IDENTIFIER=manylinux_2_34 \
  ubuntu:noble bash
```

## Adding a new platform

See the [Adding a new platform](README.md#adding-a-new-platform) section in README.md.

## Adding a patch for an R version

See [builder/patches/README.md](builder/patches/README.md).

## Important gotchas

- **Docker rebuild required**: Package scripts (`package.<platform>`) are COPYed into Docker images. After editing them, you must run `make docker-build-<platform>` before building R. Same for Dockerfiles.
- **OpenBLAS naming inconsistency**: OpenBLAS .so names differ across distros (`libopenblaso.so` on Rocky 9 vs `libopenblas.so` on Ubuntu/Alpine). This is why portable builds use a post-build BLAS swap (keeping Makeconf's `-lRblas`) rather than `--with-blas=<lib>` at configure time.
- **PCRE2 hidden for R 3.x**: `build.sh` temporarily hides PCRE2 pkg-config during configure for R < 4.0 to prevent unwanted linkage.

## macOS and Windows builds

- macOS build scripts live in `macos/`, Windows scripts in `windows/`
- These use CRAN binaries + post-processing (not compiled from source like Linux builds)
- See [`macos/README.md`](macos/README.md) and [`windows/README.md`](windows/README.md) for technical details (Mach-O patching pipeline, code signing, Inno Setup extraction, IDE compatibility, troubleshooting)
- CI workflows are `.github/workflows/build-macos.yml` and `.github/workflows/build-windows.yml`
- Makefile targets: `build-r-macos`, `test-r-macos`, `build-r-windows`, `test-r-windows`
- Portable-R startup hooks live in the **base Rprofile** (`library/base/R/Rprofile`), not `etc/Rprofile.site`, so they survive `R --vanilla` and IDE-embedded R sessions. This matches the manylinux PR #280 pattern.

## Code style

- Shell scripts use `bash` (manylinux) or `sh` (musllinux/Alpine)
- Python code uses stdlib only (no external deps beyond patchelf CLI)
- Dockerfiles include comments explaining non-obvious package choices
- Test scripts use `set -ex` for verbose output
