import argparse
import os
import json
import requests
from bs4 import BeautifulSoup
import boto3
import botocore

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

    # Command to check for new R versions
    check_parser = subparsers.add_parser("check", help="Check for new R versions.")
    check_parser.add_argument("--s3-bucket", required=True, help="S3 bucket name.")

    # Command to publish new R versions to versions.json
    publish_parser = subparsers.add_parser("publish", help="Publish new R versions.")
    publish_parser.add_argument("--s3-bucket", required=True, help="S3 bucket name.")
    publish_parser.add_argument("--dryrun", action="store_true", help="Perform a dry run without updating S3.")
    publish_parser.add_argument("--versions", required=True, help="Comma-separated list of R versions to publish.")

    args = parser.parse_args()

    if args.command == "check":
        new_versions = check_new_r_versions(args.s3_bucket)
        print(','.join(new_versions))
    elif args.command == "publish":
        new_versions = args.versions.split(',')
        publish_new_r_versions(new_versions, args.s3_bucket, dryrun=args.dryrun)

if __name__ == "__main__":
    main()
