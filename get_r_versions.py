import argparse
import json
import re
import urllib.request

VERSIONS_URL = 'https://cdn.posit.co/r/versions.json'

# Minimum R version for "all"
MIN_ALL_VERSION = '3.1.0'


def main():
    parser = argparse.ArgumentParser(description="Print R-builds R versions as JSON.")
    parser.add_argument(
        'versions',
        type=str,
        nargs='?',
        # R 3.6 is a special case, as we need longer term (but unstated) support for it.
        default='last-5,3.6.3,devel',
        help="""Comma-separated list of R versions. Specify "last-N" to use the
            last N minor R versions, or "all" to use all minor R versions since R 3.1.
            Defaults to "last-5,3.6.3,devel".
            """
    )
    args = parser.parse_args()
    versions = _get_versions(which=args.versions)
    print(json.dumps(versions))


def _get_versions(which='all'):
    supported_versions = sorted(_get_supported_versions(), reverse=True)
    versions = []
    for version in which.split(','):
        versions.extend(_expand_version(version, supported_versions))
    return versions

def _expand_version(which, supported_versions):
    last_n_versions = None
    if which.startswith('last-'):
        last_n_versions = int(which.replace('last-', ''))
    elif which != 'all':
        return [which] if which in supported_versions else []

    versions = {}
    for ver in supported_versions:
        # Skip unreleased versions (e.g., devel, next)
        if not re.match(r'[\d.]', ver):
            continue
        if ver < MIN_ALL_VERSION:
            continue
        minor_ver = tuple(ver.split('.')[0:2])
        if minor_ver not in versions:
            versions[minor_ver] = ver
    versions = sorted(list(versions.values()), reverse=True)

    if last_n_versions:
        return versions[0:last_n_versions]

    return versions


def _get_supported_versions():
    request = urllib.request.Request(VERSIONS_URL)
    response = urllib.request.urlopen(request)
    data = response.read()
    result = json.loads(data)
    return result['r_versions']


if __name__ == '__main__':
    main()
