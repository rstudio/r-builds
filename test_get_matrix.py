"""Tests for get_matrix.py, focused on keeping the Cloudsmith platform mapping
in sync with the build matrix's source of truth (PLATFORMS in the Makefile)."""
import subprocess

import get_matrix


def _makefile_platforms():
    """The authoritative platform list, straight from `make print-platforms`."""
    out = subprocess.check_output(['make', 'print-platforms'], text=True)
    return set(out.split())


def test_every_platform_is_classified():
    """Every built platform must be mapped to a Cloudsmith distro or declared
    portable, so the cloudsmith-publish job never hits an unknown platform."""
    platforms = _makefile_platforms()
    classified = set(get_matrix.CLOUDSMITH_DISTROS) | get_matrix.PORTABLE_PLATFORMS
    missing = platforms - classified
    assert not missing, (
        f"Platforms not classified for Cloudsmith publishing: {sorted(missing)}. "
        f"Add each to CLOUDSMITH_DISTROS or PORTABLE_PLATFORMS in get_matrix.py."
    )


def test_no_stale_mappings():
    """Mappings must not reference platforms that were removed from PLATFORMS."""
    platforms = _makefile_platforms()
    classified = set(get_matrix.CLOUDSMITH_DISTROS) | get_matrix.PORTABLE_PLATFORMS
    stale = classified - platforms
    assert not stale, (
        f"Cloudsmith mappings for platforms no longer in PLATFORMS: {sorted(stale)}."
    )


def test_distro_and_portable_are_disjoint():
    overlap = set(get_matrix.CLOUDSMITH_DISTROS) & get_matrix.PORTABLE_PLATFORMS
    assert not overlap, f"Platforms both mapped and marked portable: {sorted(overlap)}"


def test_cloudsmith_info_deb_platform():
    assert get_matrix.cloudsmith_info('ubuntu-2604') == {
        'distro': 'ubuntu/resolute', 'pkg_type': 'deb', 'pkg_pattern': 'r-*.deb',
    }


def test_cloudsmith_info_rpm_platform():
    info = get_matrix.cloudsmith_info('fedora-43')
    assert info == {'distro': 'fedora/43', 'pkg_type': 'rpm', 'pkg_pattern': 'R-*.rpm'}


def test_cloudsmith_info_portable_is_none():
    assert get_matrix.cloudsmith_info('manylinux_2_34') is None


def test_cloudsmith_info_unknown_raises():
    try:
        get_matrix.cloudsmith_info('does-not-exist')
    except KeyError:
        return
    raise AssertionError("expected KeyError for unknown platform")
