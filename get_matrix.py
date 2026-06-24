"""
Generates the build matrix for GitHub Actions across platforms, R versions, and architectures.

Some platforms may not support certain R versions or architectures, and this script filters out those combinations
and generates the complex build matrix.
"""
import argparse
import json
import subprocess
import sys


# Platforms whose builds are handled by dedicated reusable workflows
# (build-macos.yml, build-windows.yml) rather than the Linux Docker pipeline.
_NON_LINUX_PREFIXES = ('macos', 'windows')


# Single source of truth for the cloudsmith-publish job's platform -> Cloudsmith
# distribution mapping (consumed via `get_matrix.py --cloudsmith-info <platform>`).
# Every distro-package platform in the Makefile's PLATFORMS must appear here or
# in PORTABLE_PLATFORMS; test_get_matrix.py fails CI otherwise, so this can't
# silently drift out of sync with the build matrix.
CLOUDSMITH_DISTROS = {
    'ubuntu-2004': 'ubuntu/focal',
    'ubuntu-2204': 'ubuntu/jammy',
    'ubuntu-2404': 'ubuntu/noble',
    'ubuntu-2604': 'ubuntu/resolute',
    'debian-13': 'debian/trixie',
    'centos-7': 'el/7',
    'centos-8': 'el/8',
    'rhel-9': 'el/9',
    'rhel-10': 'el/10',
    'opensuse-156': 'opensuse/15.6',
    'opensuse-160': 'opensuse/16.0',
    'fedora-42': 'fedora/42',
    'fedora-43': 'fedora/43',
}

# Portable builds bundle their dependencies and are distributed as relocatable
# tarballs / packages via S3/CDN, not per-distro Cloudsmith repos. They are
# intentionally excluded from Cloudsmith publishing.
PORTABLE_PLATFORMS = {'manylinux_2_34', 'musllinux_1_2'}


def _is_non_linux(platform):
    return any(platform == p or platform.startswith(p + '-') for p in _NON_LINUX_PREFIXES)


def cloudsmith_info(platform):
    """Cloudsmith publish info for a platform.

    Returns a dict with ``distro``, ``pkg_type``, and ``pkg_pattern`` for
    distro-package platforms, or ``None`` for portable platforms that are not
    published to Cloudsmith. Raises ``KeyError`` for platforms that are neither
    mapped nor declared portable.
    """
    if platform in PORTABLE_PLATFORMS:
        return None
    distro = CLOUDSMITH_DISTROS[platform]  # KeyError = unclassified platform
    if distro.startswith(('ubuntu/', 'debian/')):
        pkg_type, pkg_pattern = 'deb', 'r-*.deb'
    else:
        pkg_type, pkg_pattern = 'rpm', 'R-*.rpm'
    return {'distro': distro, 'pkg_type': pkg_type, 'pkg_pattern': pkg_pattern}


def main():
    parser = argparse.ArgumentParser(description="Print R-builds platforms as JSON.")
    parser.add_argument(
        '--platforms',
        type=str,
        default='all',
        help='Comma-separated list of platforms. Specify "all" to use all platforms (the default).'
    )
    parser.add_argument(
        '--versions',
        type=str,
        help='Comma-separated list of R versions. Required unless --cloudsmith-info is given.'
    )
    parser.add_argument(
        '--arch',
        type=str,
        default='amd64,arm64',
        help='Comma-separated list of architectures.'
    )
    parser.add_argument(
        '--cloudsmith-info',
        type=str,
        metavar='PLATFORM',
        help='Print Cloudsmith publish info (JSON) for a single platform and exit. '
             'Emits {"skip": true} for portable platforms; exits non-zero for unknown ones.'
    )
    args = parser.parse_args()

    if args.cloudsmith_info:
        try:
            info = cloudsmith_info(args.cloudsmith_info)
        except KeyError:
            sys.exit(
                f"Unknown platform: {args.cloudsmith_info}. Add it to CLOUDSMITH_DISTROS "
                f"or PORTABLE_PLATFORMS in get_matrix.py."
            )
        print(json.dumps(info if info is not None else {"skip": True}))
        return

    if not args.versions:
        parser.error('--versions is required')

    # Re-set to default values if empty string/whitespace explicitly specified (""), which can happen in CI jobs
    platforms = args.platforms if args.platforms else parser.get_default('platforms')
    arch = args.arch if args.arch else parser.get_default('arch')

    platforms = [p.strip() for p in platforms.split(',')]
    versions = [v.strip() for v in args.versions.split(',')] if args.versions else []
    arch = [a.strip() for a in arch.split(',')]
    matrix = _get_matrix(platforms=platforms, versions=versions, arch=arch)
    print(json.dumps(matrix))


def _get_matrix(platforms=['all'], versions=[], arch=['amd64', 'arm64']):
    if platforms == ['all']:
        supported_platforms = subprocess.check_output(['make', 'print-platforms'], text=True)
        supported_platforms = supported_platforms.split()
        platforms = supported_platforms

    # Strip macOS/Windows selectors — they flow through build-macos.yml /
    # build-windows.yml, not the Linux Docker matrix this script feeds.
    platforms = [p for p in platforms if not _is_non_linux(p)]

    # Put all combinations in the "include" list, which allows complex matrix configurations
    include = []
    # Record the platforms, R versions, and architectures that will be built after filtering invalid combinations
    build_platforms = set()
    build_r_versions = set()
    build_arch = set()

    for platform in platforms:
        for version in versions:
            # Rules to skip certain combinations go here, e.g., old R versions that no longer build on newer platforms
            if platform == 'rhel-10' and version <= '3.6.3':
                # RHEL 10 does not support R 3.x because it does not have PCRE1
                continue
            if platform == 'debian-13' and version <= '3.6.3':
                # Debian 13 does not support R 3.x because it does not have PCRE1
                continue
            if platform == 'ubuntu-2604' and version <= '3.6.3':
                # Ubuntu 26.04 does not support R 3.x because it does not have PCRE1
                continue
            for a in arch:
                include.append({
                    "platform": platform,
                    "r_version": version,
                    "arch": a
                })
                build_platforms.add(platform)
                build_r_versions.add(version)
                build_arch.add(a)

    matrix = {"include": include}
    return {
        # matrix will be used for building R
        "matrix": matrix,
        # platforms, r_versions, and arch are used for building the Docker images and updating versions.json
        "platforms": list(build_platforms),
        "r_versions": list(build_r_versions),
        "arch": list(build_arch)
    }


if __name__ == '__main__':
    main()
