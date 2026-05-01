from build_manifest import (
    BuildRecord,
    assemble_manifest,
    build_url,
    derive_versions,
    parse_s3_key,
)

# Portable Linux tarballs ----------------------------------------------------

def test_parse_manylinux_tarball_x86_64():
    rec = parse_s3_key("r/manylinux_2_34/R-4.5.3-manylinux_2_34.tar.gz")
    assert rec == BuildRecord(r_version="4.5.3", platform="manylinux_2_34", arch="amd64",
                              filename="R-4.5.3-manylinux_2_34.tar.gz")

def test_parse_manylinux_tarball_arm64():
    rec = parse_s3_key("r/manylinux_2_34/R-4.5.3-manylinux_2_34-arm64.tar.gz")
    assert rec == BuildRecord(r_version="4.5.3", platform="manylinux_2_34", arch="arm64",
                              filename="R-4.5.3-manylinux_2_34-arm64.tar.gz")

def test_parse_musllinux_tarball():
    rec = parse_s3_key("r/musllinux_1_2/R-4.5.3-musllinux_1_2-arm64.tar.gz")
    assert rec.platform == "musllinux_1_2"
    assert rec.arch == "arm64"

def test_parse_devel_tarball():
    rec = parse_s3_key("r/manylinux_2_34/R-devel-manylinux_2_34.tar.gz")
    assert rec == BuildRecord(r_version="devel", platform="manylinux_2_34", arch="amd64",
                              filename="R-devel-manylinux_2_34.tar.gz")

# Native Linux distro packages ----------------------------------------------

def test_parse_ubuntu_deb_amd64():
    rec = parse_s3_key("r/ubuntu-2204/pkgs/r-4.5.3_1_amd64.deb")
    assert rec == BuildRecord(r_version="4.5.3", platform="ubuntu-2204", arch="amd64",
                              filename="r-4.5.3_1_amd64.deb")

def test_parse_ubuntu_deb_arm64():
    rec = parse_s3_key("r/ubuntu-2204/pkgs/r-4.5.3_1_arm64.deb")
    assert rec.arch == "arm64"

def test_parse_rhel_rpm_x86_64_normalizes_to_amd64():
    rec = parse_s3_key("r/rhel-9/pkgs/R-4.5.3-1-1.x86_64.rpm")
    assert rec == BuildRecord(r_version="4.5.3", platform="rhel-9", arch="amd64",
                              filename="R-4.5.3-1-1.x86_64.rpm")

def test_parse_rhel_rpm_aarch64_normalizes_to_arm64():
    rec = parse_s3_key("r/rhel-9/pkgs/R-4.5.3-1-1.aarch64.rpm")
    assert rec.arch == "arm64"

# macOS ---------------------------------------------------------------------

def test_parse_macos_tarball_x86_64():
    rec = parse_s3_key("r/macos/R-4.5.3-macos.tar.gz")
    assert rec == BuildRecord(r_version="4.5.3", platform="macos", arch="x86_64",
                              filename="R-4.5.3-macos.tar.gz")

def test_parse_macos_tarball_arm64():
    rec = parse_s3_key("r/macos/R-4.5.3-macos-arm64.tar.gz")
    assert rec.arch == "arm64"

# Windows -------------------------------------------------------------------

def test_parse_windows_zip():
    rec = parse_s3_key("r/windows/R-4.5.3-windows.zip")
    assert rec == BuildRecord(r_version="4.5.3", platform="windows", arch="x86_64",
                              filename="R-4.5.3-windows.zip")

# Skips ---------------------------------------------------------------------

def test_skip_sha256_sidecar():
    assert parse_s3_key("r/macos/R-4.5.3-macos.tar.gz.sha256") is None

def test_skip_versions_json():
    assert parse_s3_key("r/versions.json") is None

def test_skip_manifest_json():
    assert parse_s3_key("r/manifest.json") is None

def test_skip_unrecognized():
    assert parse_s3_key("r/macos/some-stray-file.txt") is None


def test_assemble_manifest_envelope():
    records = [
        (BuildRecord("4.5.3", "manylinux_2_34", "amd64", "R-4.5.3-manylinux_2_34.tar.gz"),
         "abc123", 100),
    ]
    manifest = assemble_manifest(records, generated_at="2026-05-01T12:00:00Z",
                                 cdn_base="https://cdn.posit.co")
    assert manifest["schema_version"] == 1
    assert manifest["generated_at"] == "2026-05-01T12:00:00Z"
    assert len(manifest["builds"]) == 1
    build = manifest["builds"][0]
    assert build["r_version"] == "4.5.3"
    assert build["platform"] == "manylinux_2_34"
    assert build["arch"] == "amd64"
    assert build["sha256"] == "abc123"
    assert build["size"] == 100
    assert build["url"] == "https://cdn.posit.co/r/manylinux_2_34/R-4.5.3-manylinux_2_34.tar.gz"


def test_assemble_manifest_sorts_stably():
    # Out-of-order input.
    inputs = [
        (BuildRecord("4.4.3", "macos", "arm64", "R-4.4.3-macos-arm64.tar.gz"), "h", 1),
        (BuildRecord("4.5.3", "macos", "x86_64", "R-4.5.3-macos.tar.gz"), "h", 1),
        (BuildRecord("4.5.3", "macos", "arm64", "R-4.5.3-macos-arm64.tar.gz"), "h", 1),
        (BuildRecord("4.5.3", "manylinux_2_34", "amd64", "R-4.5.3-manylinux_2_34.tar.gz"),
         "h", 1),
    ]
    m = assemble_manifest(inputs, generated_at="t", cdn_base="https://x")
    keys = [(b["r_version"], b["platform"], b["arch"]) for b in m["builds"]]
    # Newest version first; within version, platform then arch alphabetical.
    assert keys == [
        ("4.5.3", "macos", "arm64"),
        ("4.5.3", "macos", "x86_64"),
        ("4.5.3", "manylinux_2_34", "amd64"),
        ("4.4.3", "macos", "arm64"),
    ]


def test_derive_versions_from_manifest():
    manifest = {
        "schema_version": 1,
        "builds": [
            {"r_version": "4.5.3", "platform": "macos", "arch": "arm64"},
            {"r_version": "4.5.3", "platform": "manylinux_2_34", "arch": "amd64"},
            {"r_version": "4.4.3", "platform": "macos", "arch": "x86_64"},
            {"r_version": "devel", "platform": "manylinux_2_34", "arch": "amd64"},
        ],
    }
    assert derive_versions(manifest) == {
        "r_versions": ["devel", "4.5.3", "4.4.3"],
    }


def test_build_url():
    assert build_url("https://cdn.posit.co",
                     BuildRecord("4.5.3", "ubuntu-2204", "amd64",
                                 "r-4.5.3_1_amd64.deb"),
                     under_pkgs=True) == \
        "https://cdn.posit.co/r/ubuntu-2204/pkgs/r-4.5.3_1_amd64.deb"
    assert build_url("https://cdn.posit.co",
                     BuildRecord("4.5.3", "macos", "arm64",
                                 "R-4.5.3-macos-arm64.tar.gz"),
                     under_pkgs=False) == \
        "https://cdn.posit.co/r/macos/R-4.5.3-macos-arm64.tar.gz"


def test_assemble_with_mixed_records_orders_and_urls_correctly():
    records = [
        (BuildRecord("4.4.3", "manylinux_2_34", "amd64", "R-4.4.3-manylinux_2_34.tar.gz"),
         "a" * 64, 100),
        (BuildRecord("4.5.3", "macos", "arm64", "R-4.5.3-macos-arm64.tar.gz"),
         "b" * 64, 200),
        (BuildRecord("devel", "manylinux_2_34", "amd64", "R-devel-manylinux_2_34.tar.gz"),
         "c" * 64, 300),
        (BuildRecord("4.5.3", "ubuntu-2204", "amd64", "r-4.5.3_1_amd64.deb"),
         "d" * 64, 400),
    ]
    m = assemble_manifest(records, generated_at="2026-05-01T00:00:00Z",
                         cdn_base="https://cdn.posit.co")
    keys = [(b["r_version"], b["platform"], b["arch"]) for b in m["builds"]]
    # devel sorts to the top, then 4.5.3 (newest numeric) ahead of 4.4.3.
    # Within 4.5.3: macos < ubuntu-2204 alphabetically.
    assert keys == [
        ("devel", "manylinux_2_34", "amd64"),
        ("4.5.3", "macos", "arm64"),
        ("4.5.3", "ubuntu-2204", "amd64"),
        ("4.4.3", "manylinux_2_34", "amd64"),
    ]
    # deb URL goes under /pkgs/, tarball URL is at the platform root.
    deb_entry = next(b for b in m["builds"] if b["platform"] == "ubuntu-2204")
    assert deb_entry["url"] == "https://cdn.posit.co/r/ubuntu-2204/pkgs/r-4.5.3_1_amd64.deb"
    macos_entry = next(b for b in m["builds"] if b["platform"] == "macos")
    assert macos_entry["url"] == "https://cdn.posit.co/r/macos/R-4.5.3-macos-arm64.tar.gz"


# Native Linux tarballs (with hyphenated platform names) ----------------------

def test_parse_rhel9_tarball_x86_64():
    rec = parse_s3_key("r/rhel-9/R-4.5.3-rhel-9.tar.gz")
    assert rec == BuildRecord(r_version="4.5.3", platform="rhel-9", arch="amd64",
                              filename="R-4.5.3-rhel-9.tar.gz")

def test_parse_rhel9_tarball_arm64():
    rec = parse_s3_key("r/rhel-9/R-4.5.3-rhel-9-arm64.tar.gz")
    assert rec.arch == "arm64"
    assert rec.platform == "rhel-9"

def test_parse_ubuntu_tarball():
    rec = parse_s3_key("r/ubuntu-2204/R-4.5.3-ubuntu-2204.tar.gz")
    assert rec.platform == "ubuntu-2204"
    assert rec.arch == "amd64"

def test_parse_centos7_tarball():
    rec = parse_s3_key("r/centos-7/R-4.5.3-centos-7.tar.gz")
    assert rec.platform == "centos-7"

# musllinux APK packages ------------------------------------------------------

def test_parse_musllinux_apk_x86_64_normalizes_to_amd64():
    rec = parse_s3_key("r/musllinux_1_2/pkgs/r-4.5.3_1_x86_64.apk")
    assert rec == BuildRecord(r_version="4.5.3", platform="musllinux_1_2", arch="amd64",
                              filename="r-4.5.3_1_x86_64.apk")

def test_parse_musllinux_apk_aarch64_normalizes_to_arm64():
    rec = parse_s3_key("r/musllinux_1_2/pkgs/r-4.5.3_1_aarch64.apk")
    assert rec.arch == "arm64"


def test_derive_versions_union_logic_independent():
    """The union logic is in write_manifest (S3-aware) and isn't directly
    testable from derive_versions, but we can verify the helper that powers
    it: _versions_sort_key sorts named channels first, then numeric desc.
    """
    from build_manifest import _versions_sort_key
    inputs = ["4.4.3", "devel", "4.5.3", "next", "4.5.0"]
    inputs.sort(key=_versions_sort_key)
    assert inputs == ["devel", "next", "4.5.3", "4.5.0", "4.4.3"]
