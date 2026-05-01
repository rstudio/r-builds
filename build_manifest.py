# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "boto3",
# ]
# ///
"""Build the r-builds CDN manifest from an S3 listing.

This module parses S3 keys into typed build records, lists S3 objects under
``r/``, fetches ``.sha256`` sidecars uploaded alongside each artifact, and
writes both ``manifest.json`` (the canonical, full enumeration) and
``versions.json`` (a derived flat list of R version strings retained for
backward compatibility).

Run via uv:  ``uv run build_manifest.py write --s3-bucket BUCKET --cdn-base URL``
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import re
import sys
from typing import Iterable, Optional

import boto3


# RFC 3339 UTC, second precision. Used in manifest envelope `generated_at`.
_RFC3339_FMT = "%Y-%m-%dT%H:%M:%SZ"


@dataclasses.dataclass(frozen=True)
class BuildRecord:
    r_version: str
    platform: str
    arch: str
    filename: str


# Filename patterns. Each pattern's first capture group is the R version,
# additional groups are arch hints. Order matters: more specific patterns
# come first.
_DEB_RE = re.compile(r"^r-(?P<ver>[^_]+)_1_(?P<arch>amd64|arm64)\.deb$")
_RPM_RE = re.compile(r"^R-(?P<ver>.+?)-1-1\.(?P<arch>x86_64|aarch64)\.rpm$")
_APK_RE = re.compile(r"^r-(?P<ver>[^_]+)_1_(?P<arch>x86_64|aarch64)\.apk$")
# Lazy `.+?` for `<ver>` works for current R version strings (e.g., "4.5.3",
# "devel", "next", "patched"). A version containing a hyphen followed by a
# lowercase token shorter than the platform identifier (hypothetical, not in
# any current release) could be misparsed; revisit the regex if R ever ships
# such a version.
_TARBALL_RE = re.compile(r"^R-(?P<ver>.+?)-(?P<plat>[a-z0-9_-]+?)(?:-arm64)?\.tar\.gz$")
_WINZIP_RE = re.compile(r"^R-(?P<ver>.+?)-windows\.zip$")

# RPM-style arch suffixes get normalized to the dpkg/build-matrix convention
# (amd64/arm64) so all Linux entries in the manifest use one identifier per
# hardware target.
_RPM_ARCH_NORMALIZE = {"x86_64": "amd64", "aarch64": "arm64"}


def parse_s3_key(key: str) -> Optional[BuildRecord]:
    """Parse an S3 key under ``r/`` into a BuildRecord, or None to skip.

    Returns None for sidecar files (.sha256), index files (versions.json,
    manifest.json), and anything that does not match a known artifact
    naming pattern.
    """
    if not key.startswith("r/"):
        return None
    if key.endswith(".sha256"):
        return None
    parts = key.split("/")
    # Valid keys: r/<platform>/<filename>     (3 parts)
    #          or r/<platform>/pkgs/<filename> (4 parts with "pkgs" as parts[2])
    if len(parts) == 3:
        pass  # platform-root artifact
    elif len(parts) == 4 and parts[2] == "pkgs":
        pass  # native distro deb/rpm/apk
    else:
        return None  # versions.json, manifest.json, or unexpected nesting
    platform = parts[1]
    filename = parts[-1]

    # Native distro debs and rpms live under r/<platform>/pkgs/<filename>.
    if "/pkgs/" in key:
        m = _DEB_RE.match(filename)
        if m:
            return BuildRecord(
                r_version=m["ver"],
                platform=platform,
                arch=m["arch"],
                filename=filename,
            )
        m = _RPM_RE.match(filename)
        if m:
            return BuildRecord(
                r_version=m["ver"],
                platform=platform,
                arch=_RPM_ARCH_NORMALIZE[m["arch"]],
                filename=filename,
            )
        m = _APK_RE.match(filename)
        if m:
            return BuildRecord(
                r_version=m["ver"],
                platform=platform,
                arch=_RPM_ARCH_NORMALIZE[m["arch"]],
                filename=filename,
            )
        return None

    # Windows zip.
    if platform == "windows":
        m = _WINZIP_RE.match(filename)
        if m:
            return BuildRecord(
                r_version=m["ver"],
                platform="windows",
                arch="x86_64",
                filename=filename,
            )
        return None

    # macOS tarball. Two shapes: R-<ver>-macos.tar.gz (x86_64) and
    # R-<ver>-macos-arm64.tar.gz (arm64).
    if platform == "macos":
        m = _TARBALL_RE.match(filename)
        if m and m["plat"] == "macos":
            arch = "arm64" if filename.endswith("-arm64.tar.gz") else "x86_64"
            return BuildRecord(
                r_version=m["ver"],
                platform="macos",
                arch=arch,
                filename=filename,
            )
        return None

    # Portable Linux tarball (manylinux/musllinux). Same naming convention
    # as macOS but with platform = manylinux_2_34 / musllinux_1_2 and the
    # Linux arch convention (amd64/arm64).
    m = _TARBALL_RE.match(filename)
    if m and m["plat"] == platform:
        arch = "arm64" if filename.endswith("-arm64.tar.gz") else "amd64"
        return BuildRecord(
            r_version=m["ver"],
            platform=platform,
            arch=arch,
            filename=filename,
        )
    return None


def build_url(cdn_base: str, rec: BuildRecord, under_pkgs: bool) -> str:
    """Construct a fully-qualified CDN URL for a build artifact."""
    suffix = "/pkgs/" if under_pkgs else "/"
    return f"{cdn_base}/r/{rec.platform}{suffix}{rec.filename}"


def _version_sort_key(version: str):
    """Sort key for R version strings.

    Numeric versions sort by tuple (descending). Named channels (devel, next,
    patched) sort above all numeric versions in a stable order.
    """
    named_order = {"devel": 0, "next": 1, "patched": 2}
    if version in named_order:
        # Named channels: tuple length matches numeric path so comparison is total.
        return (0, named_order[version], 0, 0)
    parts = version.split(".")
    try:
        nums = tuple(int(p) for p in parts)
    except ValueError:
        # Unknown form — sort to the end deterministically.
        return (2, version, 0, 0)
    # Pad to length 3 so 4.5 and 4.5.0 compare equal-ish.
    while len(nums) < 3:
        nums = nums + (0,)
    return (1,) + nums


def _build_sort_key(b: dict) -> tuple:
    """Sort key for an assembled build dict.

    Named channels (devel, next, patched) sort to the top in fixed order.
    Numeric versions sort newest-first. Within a version, platform then
    arch alphabetical.
    """
    vk = _version_sort_key(b["r_version"])
    if vk[0] == 0:
        return (0, vk[1], b["platform"], b["arch"])
    if vk[0] == 1:
        # Negate to sort newest-first under ascending sort (4.5 > 4.4 → -4.5 < -4.4).
        return (1, -vk[1], -vk[2], -vk[3], b["platform"], b["arch"])
    return (2, b["r_version"], b["platform"], b["arch"])


def assemble_manifest(
    inputs: Iterable[tuple[BuildRecord, str, int]],
    *,
    generated_at: str,
    cdn_base: str,
) -> dict:
    """Build the manifest dict from (record, sha256, size) tuples."""
    builds = []
    for rec, sha256, size in inputs:
        # deb/rpm live under <platform>/pkgs/, everything else is at the
        # platform root.
        under_pkgs = rec.filename.endswith((".deb", ".rpm", ".apk"))
        builds.append({
            "r_version": rec.r_version,
            "platform": rec.platform,
            "arch": rec.arch,
            "url": build_url(cdn_base, rec, under_pkgs=under_pkgs),
            "sha256": sha256,
            "size": size,
        })
    builds.sort(key=_build_sort_key)
    return {
        "schema_version": 1,
        "generated_at": generated_at,
        "builds": builds,
    }


def _versions_sort_key(version: str) -> tuple:
    """Sort key for versions.json: named channels first (devel, next,
    patched in that order), then numeric versions newest-first."""
    vk = _version_sort_key(version)
    if vk[0] == 0:
        return (0, vk[1])
    if vk[0] == 1:
        # Negate to sort newest-first under ascending sort.
        return (1, -vk[1], -vk[2], -vk[3])
    return (2, version)


def derive_versions(manifest: dict) -> dict:
    """Build the legacy versions.json content from the manifest."""
    versions = list(dict.fromkeys(b["r_version"] for b in manifest["builds"]))
    versions.sort(key=_versions_sort_key)
    return {"r_versions": versions}


def list_artifacts(s3_client, bucket: str) -> list[tuple[BuildRecord, str, int]]:
    """List all artifacts under ``r/`` in the bucket and pair each with its
    sha256 sidecar contents and size.

    Skips artifacts whose .sha256 sidecar is missing — they will be filled
    in by the next CI run that publishes them, or by the backfill script.
    """
    paginator = s3_client.get_paginator("list_objects_v2")
    keys: dict[str, int] = {}
    for page in paginator.paginate(Bucket=bucket, Prefix="r/"):
        for obj in page.get("Contents", []) or []:
            keys[obj["Key"]] = obj["Size"]

    results: list[tuple[BuildRecord, str, int]] = []
    for key, size in keys.items():
        rec = parse_s3_key(key)
        if rec is None:
            continue
        sha_key = f"{key}.sha256"
        if sha_key not in keys:
            print(f"WARNING: sidecar missing for {key}; skipping", file=sys.stderr)
            continue
        body = s3_client.get_object(Bucket=bucket, Key=sha_key)["Body"].read()
        sha256 = body.decode("utf-8").strip().split()[0]
        if len(sha256) != 64 or not all(c in "0123456789abcdef" for c in sha256):
            print(f"WARNING: malformed sidecar for {key}; skipping", file=sys.stderr)
            continue
        results.append((rec, sha256, size))
    return results


def write_manifest(bucket: str, cdn_base: str, dry_run: bool = False) -> None:
    """List S3, build manifest.json and versions.json, upload both."""
    cdn_base = cdn_base.rstrip("/")
    s3 = boto3.client("s3")
    inputs = list_artifacts(s3, bucket)
    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime(_RFC3339_FMT)
    manifest = assemble_manifest(inputs, generated_at=generated_at, cdn_base=cdn_base)
    versions = derive_versions(manifest)

    # Read existing versions.json from S3 and union with the newly-derived
    # version list. Without this, a consolidator run before the sha256
    # sidecar backfill is complete would shrink versions.json from ~80 R
    # versions to whatever subset has sidecars, breaking install.sh and
    # every external consumer that fetches the legacy index. Union semantics
    # match the additive behavior of the old `manage_r_versions.py publish`
    # command and preserve the design contract that versions.json keeps its
    # "exact current content and shape".
    try:
        existing_body = s3.get_object(Bucket=bucket, Key="r/versions.json")["Body"].read()
        existing = json.loads(existing_body).get("r_versions", [])
    except s3.exceptions.NoSuchKey:
        existing = []
    union = list(dict.fromkeys(list(existing) + versions["r_versions"]))
    union.sort(key=_versions_sort_key)
    versions = {"r_versions": union}

    manifest_body = json.dumps(manifest, indent=2).encode("utf-8")
    versions_body = json.dumps(versions).encode("utf-8")

    print(f"Manifest: {len(manifest['builds'])} builds, "
          f"{len(versions['r_versions'])} R versions", file=sys.stderr)

    if dry_run:
        print("Dry run: not uploading.", file=sys.stderr)
        sys.stdout.write(manifest_body.decode("utf-8"))
        return

    s3.put_object(
        Bucket=bucket,
        Key="r/manifest.json",
        Body=manifest_body,
        ContentType="application/json",
        ACL="public-read",
        CacheControl="public, max-age=300",
    )
    s3.put_object(
        Bucket=bucket,
        Key="r/versions.json",
        Body=versions_body,
        ContentType="application/json",
        ACL="public-read",
        CacheControl="public, max-age=300",
    )
    print(f"Uploaded r/manifest.json and r/versions.json to s3://{bucket}/",
          file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the r-builds CDN manifest.")
    sub = parser.add_subparsers(dest="command", required=True)

    write = sub.add_parser("write", help="Build manifest from S3 listing and upload it.")
    write.add_argument("--s3-bucket", required=True)
    write.add_argument("--cdn-base", required=True,
                       help="CDN base URL, e.g. https://cdn.posit.co")
    write.add_argument("--dry-run", action="store_true",
                       help="Print the manifest to stdout instead of uploading.")

    args = parser.parse_args()
    if args.command == "write":
        write_manifest(args.s3_bucket, args.cdn_base, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
