import os
from bs4 import BeautifulSoup
import requests
import json
import boto3
import botocore

CRAN_SRC_R3_URL = 'https://cran.rstudio.com/src/base/R-3/'
CRAN_SRC_R4_URL = 'https://cran.rstudio.com/src/base/R-4/'
batch_client = boto3.client('batch', region_name='us-east-1')
sns_client = boto3.client('sns', region_name='us-east-1')


class JobDetails:
    def __init__(self, version, platform):
        self.version = version
        self.platform = platform

    @classmethod
    def from_job_name(cls, job_name):
        _R, version, platform = job_name.split('-', 2)
        return cls(version.replace('_', '.'), platform)

    def job_name(self):
        return f"R-{self.version.replace('.', '_')}-{self.platform}"

    def job_definition_arn(self):
        return os.environ[f"JOB_DEFINITION_ARN_{self.platform.replace('-','_')}"]

    def to_json(self):
        return {'version': self.version, 'platform': self.platform}


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
        if href.startswith('R-') and href.endswith('.tar.gz'):
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
    job_details = JobDetails(version, platform)

    args = {
        'jobName': job_details.job_name(),
        'jobQueue': os.environ['JOB_QUEUE_ARN'],
        'jobDefinition': job_details.job_definition_arn(),
        'containerOverrides': _container_overrides(job_details.version)
    }
    if os.environ.get('DRYRUN'):
        print('DRYRUN: would have queued {}'.format(job_details.job_name()))
        return 'dryrun-no-job-{}'.format(job_details.job_name())
    else:
        response = batch_client.submit_job(**args)
        print("Started job with details:{},id:{}".format(job_details, response['jobId']))
        return response['jobId']


def _versions_to_build(force, versions):
    cran_versions = _cran_all_r_versions()['r_versions']
    if versions:
        cran_versions = [v for v in cran_versions if v in versions]
    known_versions = _known_r_versions()['r_versions']
    new_versions = _compare_versions(cran_versions, known_versions)

    if len(new_versions) > 0:
        print('New R Versions found on CRAN: %s' % new_versions)
        _persist_r_versions(_cran_all_r_versions())
    elif versions is None:
        # Always publish versions.json for full versions builds
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


def finished(event, _context):
    """Publish details about successfully finished jobs."""

    # first, if there were no succeeded jobs, return instead of publishing details about builds
    if len(event['succeededJobIds']) < 1:
        return event

    # fetch all jobs, removing those which are not in our succeeded id list
    r = batch_client.list_jobs(jobQueue=os.environ['JOB_QUEUE_ARN'], jobStatus='SUCCEEDED')
    print(f'r: {r}')
    succeeded_jobs = [i for i in r['jobSummaryList'] if i['jobId'] in event['succeededJobIds']]

    message = {'versions': []}

    for job in succeeded_jobs:
        details = JobDetails.from_job_name(job['jobName'])
        # exclude next/devel version from list (for now).
        if details.version in ['next', 'devel']:
            continue
        message['versions'].append(vars(details))

    # don't publish if we've excluded all successful builds
    if message['versions']:
        response = sns_client.publish(
            TargetArn=os.environ['SNS_TOPIC_ARN'],
            Message=json.dumps(message),
        )
        print(f'Published to topic, response:{response}')
    return event
