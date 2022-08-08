import os
from bs4 import BeautifulSoup
import requests
import json
import boto3
import botocore

CRAN_SRC_R3_URL = 'https://cran.rstudio.com/src/base/R-3/'
CRAN_SRC_R4_URL = 'https://cran.rstudio.com/src/base/R-4/'
batch_client = boto3.client('batch', region_name='us-east-1')


def _to_list(input):
    """Normalize a list (list or string) to list."""
    if isinstance(input, list):
        return input
    return input.split(',')


def _persist_r_versions(data):
    """Ship current list to s3."""
    s3 = boto3.resource('s3')
    obj = s3.Object(os.environ['S3_BUCKET'], 'r/versions.json')
    obj.put(Body=json.dumps(data), ContentType='application/json')


def _cran_r_versions(url):
    """Perform a lookup of CRAN-known R version."""
    r = requests.get(url)
    soup = BeautifulSoup(r.text, 'html.parser')
    r_versions = []
    for link in soup.find_all('a'):
        href = link.get('href')
        if 'R-' in href:
            v = href.replace('.tar.gz', '').replace('R-', '')
            if '-revised' not in v:  # reject 3.2.4-revised
                r_versions.append(v)
    return r_versions


def _cran_all_r_versions():
    """Perform a lookup of CRAN-known R version."""
    r_versions = []
    r_versions.extend(_cran_r_versions(CRAN_SRC_R3_URL))
    r_versions.extend(_cran_r_versions(CRAN_SRC_R4_URL))
    r_versions.append('next')
    r_versions.append('devel')
    return {'r_versions': r_versions}


def _known_r_versions():
    """Ship current list to s3."""
    try:
        s3 = boto3.resource('s3')
        obj = s3.Object(os.environ['S3_BUCKET'], 'r/versions.json')
        str = obj.get()['Body'].read().decode('utf-8')
    except botocore.exceptions.ClientError:
        print('Key not found, using empty list')
        str = '{"r_versions":[]}'
    return json.loads(str)


def _compare_versions(fresh, known):
    """Compare fresh cran list to new list and return unknown versions."""
    new = set(fresh) - set(known)
    return list(new)


def _container_overrides(version):
    """Generate container override parameter for jobs."""
    overrides = {}
    overrides['environment'] = [
        {'name': 'R_VERSION', 'value': version},
        {'name': 'S3_BUCKET', 'value': os.environ['S3_BUCKET']}
    ]
    return overrides


def _submit_job(version, platform):
    """Submit an R build job to AWS Batch."""
    job_name = '-'.join(['R', version, platform])
    job_name = job_name.replace('.', '_')
    job_definition_arn = 'JOB_DEFINITION_ARN_{}'.format(platform.replace('-','_'))
    args = {
        'jobName': job_name,
        'jobQueue': os.environ['JOB_QUEUE_ARN'],
        'jobDefinition': os.environ[job_definition_arn],
        'containerOverrides': _container_overrides(version)
    }
    if os.environ.get('DRYRUN'):
        print('DRYRUN: would have queued {}'.format(job_name))
        return 'dryrun-no-job-{}'.format(job_name)
    else:
        response = batch_client.submit_job(**args)
        print("Started job for R:{},Platform:{},id:{}".format(version, platform, response['jobId']))
        return response['jobId']


def _versions_to_build(force, versions):
    cran_versions = _cran_all_r_versions()['r_versions']
    if versions:
        cran_versions = [v for v in cran_versions if v in versions]
    known_versions = _known_r_versions()['r_versions']
    new_versions = _compare_versions(cran_versions, known_versions)

    if len(new_versions) > 0:
        print('New R Versions found: %s' % new_versions)
        _persist_r_versions(_cran_all_r_versions())

    if force in [True, 'True', 'true']:
        return cran_versions
    else:
        return new_versions


def _check_for_job_status(jobs, status):
    """Return a subset of job ids which match a given status."""
    r = batch_client.list_jobs(jobQueue=os.environ['JOB_QUEUE_ARN'], jobStatus=status)
    return [i['jobId'] for i in r['jobSummaryList'] if i['jobId'] in jobs]


def queue_builds(event, context):
    """Queue some builds."""
    event['versions_to_build'] =  _versions_to_build(event.get('force', False), event.get('versions'))
    event['supported_platforms'] = _to_list(os.environ.get('SUPPORTED_PLATFORMS', 'ubuntu-2004'))
    job_ids = []
    for version in event['versions_to_build']:
        for platform in event['supported_platforms']:
            # In R 3.3.0, 3.3.1, and 3.3.2, the configure script check for the
            # zlib version fails to handle versions longer than 5 characters.
            # Skip builds affected by this bug.
            if platform in [
                'ubuntu-2204',
                'ubuntu-2004',
                'ubuntu-1804',
                'opensuse-153',
                'centos-8',
                'rhel-9',
                'debian-10',
                'debian-11',
            ] and version in ['3.3.0', '3.3.1', '3.3.2']:
                continue
            job_ids.append(_submit_job(version, platform))
    event['jobIds'] = job_ids
    return event


def poll_running_jobs(event, context):
    """Query job queue for current queue depth."""
    event['failedJobIds'] = _check_for_job_status(event['jobIds'], 'FAILED')
    event['succeededJobIds'] = _check_for_job_status(event['jobIds'], 'SUCCEEDED')
    event['failedJobCount'] = len(event['failedJobIds'])
    event['finishedJobCount'] = len(event['failedJobIds']) + len(event['succeededJobIds'])
    event['unfinishedJobCount'] = len(event['jobIds']) - event['finishedJobCount']
    return event
