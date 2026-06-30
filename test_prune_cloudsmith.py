"""Tests for prune_cloudsmith.select_versions_to_delete — the logic that
decides which Cloudsmith package versions get deleted. The cloudsmith CLI I/O
is not exercised here; only the pure selection logic, which is what determines
whether anything gets destroyed."""
import pytest

import prune_cloudsmith


def _pkg(name, version, distro='fedora/42', arch='x86_64', uploaded=None):
    """Build a package dict shaped like cloudsmith `list packages -F json`."""
    return {
        'name': name,
        'version': version,
        'distro_version': {'slug': distro},
        'architectures': [{'name': arch}],
        'uploaded_at': uploaded or f'2026-06-{version[-2:]}T04:00:00Z',
        'slug_perm': f'{name}-{version}-{distro}-{arch}'.replace('/', '-'),
    }


def _names(pkgs):
    return sorted((p['name'], p['version']) for p in pkgs)


def test_keeps_newest_n_per_coordinate():
    pkgs = [_pkg('R-next', f'202606{d:02d}') for d in range(1, 11)]  # 10 builds
    to_delete = prune_cloudsmith.select_versions_to_delete(pkgs, keep=3)
    # Deletes the 7 oldest, keeps 20260608/09/10.
    assert len(to_delete) == 7
    assert _names(to_delete) == [('R-next', f'202606{d:02d}') for d in range(1, 8)]


def test_fewer_than_keep_deletes_nothing():
    pkgs = [_pkg('R-devel', '20260601'), _pkg('R-devel', '20260602')]
    assert prune_cloudsmith.select_versions_to_delete(pkgs, keep=14) == []


def test_coordinates_are_independent():
    # Same name+version across two distros and two arches = four coordinates,
    # each trimmed to its own newest-N.
    pkgs = []
    for distro in ('fedora/42', 'el/9'):
        for arch in ('x86_64', 'aarch64'):
            for d in range(1, 6):  # 5 builds per coordinate
                pkgs.append(_pkg('R-next', f'202606{d:02d}', distro=distro, arch=arch))
    to_delete = prune_cloudsmith.select_versions_to_delete(pkgs, keep=2)
    # 4 coordinates * (5 - 2) = 12 deletions; each coordinate keeps its 2 newest.
    assert len(to_delete) == 12
    kept = [p for p in pkgs if p not in to_delete]
    by_coord = {}
    for p in kept:
        by_coord.setdefault(prune_cloudsmith._coordinate(p), []).append(p['version'])
    assert len(by_coord) == 4
    for versions in by_coord.values():
        assert sorted(versions) == ['20260604', '20260605']


def test_release_packages_are_never_deleted():
    # A pile of stable release builds plus one nightly; only nightlies are eligible,
    # and a single nightly version is under any keep threshold.
    pkgs = [_pkg('R-4.4.3', '1'), _pkg('R-4.5.0', '1'), _pkg('r-4.4.3', '1'),
            _pkg('R-next', '20260624')]
    assert prune_cloudsmith.select_versions_to_delete(pkgs, keep=1) == []


def test_deb_and_rpm_names_both_eligible():
    rpm = [_pkg('R-next', f'202606{d:02d}') for d in range(1, 5)]
    deb = [_pkg('r-next', f'202606{d:02d}', distro='ubuntu/noble') for d in range(1, 5)]
    to_delete = prune_cloudsmith.select_versions_to_delete(rpm + deb, keep=1)
    # Two coordinates, each keeps 1, deletes 3.
    assert len(to_delete) == 6
    assert {p['name'] for p in to_delete} == {'R-next', 'r-next'}


def test_keep_zero_is_rejected():
    with pytest.raises(ValueError):
        prune_cloudsmith.select_versions_to_delete([], keep=0)
