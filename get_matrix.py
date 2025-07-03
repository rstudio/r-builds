"""
Generates the build matrix for GitHub Actions across platforms, R versions, and architectures.

Some platforms may not support certain R versions or architectures, and this script filters out those combinations
and generates the complex build matrix.
"""
import argparse
import json
import subprocess


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
        required=True,
        help='Comma-separated list of R versions.'
    )
    parser.add_argument(
        '--arch',
        type=str,
        default='amd64,arm64',
        help='Comma-separated list of architectures.'
    )
    args = parser.parse_args()
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
