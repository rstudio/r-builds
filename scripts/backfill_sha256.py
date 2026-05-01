# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "boto3",
# ]
# ///
"""Backfill sha256 sidecars for existing artifacts on the r-builds CDN.

One-shot maintenance tool. Run once per S3 bucket (staging, production)
before the manifest workflow is enabled.

For every object under ``r/`` that is not itself a sidecar, index file, or
unrelated stray, compute sha256 and upload ``<key>.sha256`` if missing.
Safe to re-run: existing sidecars are skipped.

Usage:
    uv run scripts/backfill_sha256.py --s3-bucket BUCKET [--dry-run] [--workers N]
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import sys
import os

# Allow importing build_manifest from the repo root.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), os.pardir))

import boto3  # noqa: E402

from build_manifest import parse_s3_key  # noqa: E402


def _hash_object(s3, bucket: str, key: str) -> str:
    """Stream the object body and return the lowercase hex sha256."""
    h = hashlib.sha256()
    body = s3.get_object(Bucket=bucket, Key=key)["Body"]
    for chunk in iter(lambda: body.read(8 * 1024 * 1024), b""):
        h.update(chunk)
    return h.hexdigest()


def _process_one(bucket: str, key: str, existing_sidecars: set[str], dry_run: bool) -> str:
    s3 = boto3.client("s3")
    sha_key = f"{key}.sha256"
    if sha_key in existing_sidecars:
        return f"skip (sidecar exists): {key}"
    digest = _hash_object(s3, bucket, key)
    basename = key.rsplit("/", 1)[-1]
    body = f"{digest}  {basename}\n".encode("utf-8")
    if dry_run:
        return f"would upload {sha_key}: {digest}"
    s3.put_object(
        Bucket=bucket,
        Key=sha_key,
        Body=body,
        ContentType="text/plain",
        ACL="public-read",
    )
    return f"uploaded {sha_key}: {digest}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--s3-bucket", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--workers", type=int, default=8,
                        help="Concurrent download/upload workers (default: 8)")
    args = parser.parse_args()

    s3 = boto3.client("s3")
    paginator = s3.get_paginator("list_objects_v2")
    artifact_keys: list[str] = []
    sidecars: set[str] = set()
    for page in paginator.paginate(Bucket=args.s3_bucket, Prefix="r/"):
        for obj in page.get("Contents", []) or []:
            k = obj["Key"]
            if k.endswith(".sha256"):
                sidecars.add(k)
            elif parse_s3_key(k) is not None:
                artifact_keys.append(k)

    print(f"{len(artifact_keys)} artifacts, {len(sidecars)} existing sidecars")

    with cf.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [
            pool.submit(_process_one, args.s3_bucket, k, sidecars, args.dry_run)
            for k in artifact_keys
        ]
        for fut in cf.as_completed(futures):
            print(fut.result())


if __name__ == "__main__":
    main()
