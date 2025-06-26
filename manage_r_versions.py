import argparse
import json
import re
import requests
from bs4 import BeautifulSoup
import boto3
import botocore

# Minimum R version for "all" specifier
MIN_ALL_VERSION = '3.1.0'

CRAN_SRC_R3_URL = "https://cran.r-project.org/src/base/R-3/"
CRAN_SRC_R4_URL = "https://cran.r-project.org/src/base/R-4/"

def _cran_r_versions(url):
    """Perform a lookup of CRAN-known R version."""
    r = requests.get(url)
    soup = BeautifulSoup(r.text, 'html.parser')
    r_versions = []
    for link in soup.find_all('a'):
        href = link.get('href')
        if href.startswith('R-') and href.endswith('.tar.gz'):
            v = href.replace('.tar.gz', '').replace('R-', '')
            if '-revised' not in v:  # reject 3.2.4-revised
                r_versions.append(v)
    return r_versions

def _cran_all_r_versions():
    """Perform a lookup of CRAN-known R versions."""
    r_versions = []
    r_versions.extend(_cran_r_versions(CRAN_SRC_R3_URL))
    r_versions.extend(_cran_r_versions(CRAN_SRC_R4_URL))
    r_versions.append('next')
    r_versions.append('devel')
    return r_versions

def _known_r_versions(s3_bucket):
    """Fetch the current list of known R versions from the CDN."""
    try:
        s3 = boto3.resource('s3')
        obj = s3.Object(s3_bucket, 'r/versions.json')
        r_versions = json.loads(obj.get()['Body'].read().decode('utf-8'))
        return r_versions
    except botocore.exceptions.ClientError:
        print(f'Error retrieving r/versions.json from S3 bucket {s3_bucket}')
    return {"r_versions": []}

def _expand_version(which, supported_versions):
    if which == 'all-patch':
        return supported_versions

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

def get_versions(which='all'):
    """Get R versions, filtering out any invalid versions.

    Args:
        which (str): Comma-separated list of R versions to retrieve.
                     Use "all" to get all known versions, or "last-N" to get the last N minor versions.
                     Returns: List of valid R versions.
    """
    all_versions = sorted(_cran_all_r_versions(), reverse=True)

    versions = []
    for version in which.split(','):
        version = version.strip()
        versions.extend(_expand_version(version, all_versions))
    return versions

def check_new_r_versions(s3_bucket):
    """Check for new R versions that have not been built."""
    known_versions = _known_r_versions(s3_bucket)["r_versions"]
    all_versions = _cran_all_r_versions()
    new_versions = [v for v in all_versions if v not in known_versions]
    return new_versions

def publish_new_r_versions(new_versions, s3_bucket, dryrun=True):
    """Update versions.json with newly built R versions."""
    s3 = boto3.resource('s3')
    versions = _known_r_versions(s3_bucket)
    r_versions = versions['r_versions']
    r_versions.extend(new_versions)
    # Deduplicate and filter out empty/invalid versions that may end up here by mistake
    r_versions = sorted(set(r_versions), reverse=True)
    r_versions = list(filter(None, r_versions))
    versions['r_versions'] = r_versions

    print('New versions:', versions)

    if dryrun:
        print('Dry run: not updating versions.json')
    else:
        print('Publishing new versions to S3')
        versions_json = json.dumps(versions)
        obj = s3.Object(s3_bucket, 'r/versions.json')
        obj.put(Body=versions_json, ContentType='application/json')

def main():
    parser = argparse.ArgumentParser(description="Manage R versions.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Command to get R versions
    get_parser = subparsers.add_parser("get", help="Get R versions as a comma-separated list, filtering out any invalid versions.")
    get_parser.add_argument(
        'versions',
        type=str,
        nargs='?',
        # R 3.6 is a special case, as we need longer term (but unstated) support for it.
        default='last-5,3.6.3,devel',
        help="""Comma-separated list of R versions. Specify "last-N" to use the
            last N minor R versions, or "all" to use all minor R versions since R 3.1.
            Use "all-patch" to get all known patch R versions.
            Defaults to "last-5,3.6.3,devel".
            """
    )

    # Command to check for new R versions
    check_parser = subparsers.add_parser("check", help="Check for new R versions.")
    check_parser.add_argument("--s3-bucket", required=True, help="S3 bucket name.")

    # Command to publish new R versions to versions.json
    publish_parser = subparsers.add_parser("publish", help="Publish new R versions.")
    publish_parser.add_argument("--s3-bucket", required=True, help="S3 bucket name.")
    publish_parser.add_argument("--dryrun", action="store_true", help="Perform a dry run without updating S3.")
    publish_parser.add_argument("--versions", required=True, help="Comma-separated list of R versions to publish.")

    args = parser.parse_args()

    if args.command == "get":
        # Re-set to default value if empty string/whitespace explicitly specified (""), which can happen in CI jobs
        which_versions = args.versions.strip()
        which_versions = which_versions if which_versions else get_parser.get_default('versions')
        versions = get_versions(which=which_versions)
        print(','.join(versions))
    if args.command == "check":
        new_versions = check_new_r_versions(args.s3_bucket)
        print(','.join(new_versions))
    elif args.command == "publish":
        new_versions = args.versions.split(',')
        publish_new_r_versions(new_versions, args.s3_bucket, dryrun=args.dryrun)

if __name__ == "__main__":
    main()
