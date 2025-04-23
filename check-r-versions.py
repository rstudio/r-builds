import os
import json
import requests
from bs4 import BeautifulSoup

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
    return {'r_versions': r_versions}

def _known_r_versions():
    """Fetch the current list of known R versions from the CDN."""
    try:
        response = requests.get("https://cdn.posit.co/r/versions.json")
        str = response.text
    except requests.exceptions.RequestException:
        print('Error retrieving versions.json, using empty list')
        str = '{"r_versions":[]}'
    return json.loads(str)

def check_new_r_versions():
    """Check for new R versions that have not been built."""
    known_versions = _known_r_versions().get('r_versions', [])
    all_versions = _cran_all_r_versions().get('r_versions', [])
    new_versions = [v for v in all_versions if v not in known_versions]
    print(','.join(new_versions))

if __name__ == "__main__":
    check_new_r_versions()
