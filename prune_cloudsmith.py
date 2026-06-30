"""Prune old R-devel / R-next nightly packages from a Cloudsmith repository.

The daily devel/next builds publish a new date-versioned package for every
platform and architecture, which would otherwise accumulate in the repository
without bound. This keeps the newest N versions of each package *coordinate*
(name + distribution + architecture) and deletes the rest.

Only the rolling nightly package names are ever considered (R-next / R-devel,
and the deb-cased r-next / r-devel), so stable release packages such as
R-4.4.3 are never deletion candidates even when they share the repository.

Retention is by count, not age: keeping the newest N per coordinate means an
outage or a string of failed builds can never prune a coordinate below N
versions (age-based retention could delete everything if nothing fresh is
published to replace what ages out).

Listing and deletion go through the cloudsmith CLI (already used by the
publish step); the selection logic is pure and unit-tested in
test_prune_cloudsmith.py.
"""
import argparse
import json
import subprocess
import sys
from collections import defaultdict

# Rolling nightly packages we manage. rpm packages are named R-*, deb packages
# r-*. Anything else in the repo (release builds, other products) is left alone.
PRUNE_NAMES = frozenset({'R-next', 'R-devel', 'r-next', 'r-devel'})

# Cap the server-side query; we page until a short page is returned.
_PAGE_SIZE = 100


def _coordinate(pkg):
    """Key whose newest N versions are retained: (name, distribution, arch).

    Builds of the same coordinate differ only by version (the date), so they
    are the set we trim. Distribution distinguishes e.g. fedora/42 from el/9,
    which can share an rpm filename, so it must be part of the key.
    """
    name = pkg.get('name', '')
    # Key on both the distro family and its version slug: version slugs alone
    # (e.g. "9", "10") could collide across distro families.
    distro_family = (pkg.get('distro') or {}).get('slug', '')
    distro_version = (pkg.get('distro_version') or {}).get('slug', '')
    arch = ','.join(sorted(a.get('name', '') for a in (pkg.get('architectures') or [])))
    return (name, distro_family, distro_version, arch)


def _uploaded(pkg):
    # ISO-8601 timestamps sort lexicographically; version (the date) is a tiebreaker.
    return (pkg.get('uploaded_at') or '', pkg.get('version') or '')


def _identifier(pkg):
    """The permanent slug the cloudsmith CLI uses to address a package version."""
    return pkg.get('slug_perm') or pkg.get('identifier_perm') or pkg.get('slug')


def select_versions_to_delete(packages, keep):
    """Return the package dicts to delete: for each coordinate, everything
    except the ``keep`` most-recently-uploaded versions. Non-nightly packages
    are never selected."""
    if keep < 1:
        raise ValueError('keep must be >= 1')
    by_coord = defaultdict(list)
    for pkg in packages:
        if pkg.get('name') in PRUNE_NAMES:
            by_coord[_coordinate(pkg)].append(pkg)

    to_delete = []
    for pkgs in by_coord.values():
        pkgs.sort(key=_uploaded, reverse=True)
        to_delete.extend(pkgs[keep:])
    return to_delete


def list_packages(repo):
    """List the nightly packages in ``repo`` (owner/name) via the cloudsmith CLI."""
    query = ' OR '.join(f'name:{name}' for name in sorted(PRUNE_NAMES))
    packages = []
    page = 1
    while True:
        out = subprocess.check_output(
            ['cloudsmith', 'list', 'packages', repo, '-q', query,
             '-F', 'json', '--page', str(page), '--page-size', str(_PAGE_SIZE)],
            text=True,
        )
        payload = json.loads(out)
        data = payload.get('data', []) if isinstance(payload, dict) else payload
        packages.extend(data)
        if len(data) < _PAGE_SIZE:
            return packages
        page += 1


def delete_package(repo, identifier, dry_run):
    target = f'{repo}/{identifier}'
    if dry_run:
        print(f'[dry-run] would delete {target}')
        return
    subprocess.check_call(['cloudsmith', 'delete', '-y', target])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True,
                        help='Cloudsmith repository, e.g. "posit/open".')
    parser.add_argument('--keep', type=int, default=14,
                        help='Number of newest versions to keep per coordinate (default 14).')
    parser.add_argument('--dry-run', action='store_true',
                        help='List what would be deleted without deleting anything.')
    args = parser.parse_args()

    packages = list_packages(args.repo)
    to_delete = select_versions_to_delete(packages, args.keep)
    print(f'Found {len(packages)} R-next/R-devel packages in {args.repo}; '
          f'keeping newest {args.keep} per coordinate, deleting {len(to_delete)}.')

    for pkg in to_delete:
        identifier = _identifier(pkg)
        if not identifier:
            print(f'WARNING: no identifier for {pkg.get("name")} {pkg.get("version")}; skipping',
                  file=sys.stderr)
            continue
        print(f'delete {pkg.get("name")} {pkg.get("version")} {_coordinate(pkg)} -> {identifier}')
        delete_package(args.repo, identifier, args.dry_run)


if __name__ == '__main__':
    main()
