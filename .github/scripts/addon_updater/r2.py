"""
Cloudflare R2 access.

Mirrors what cexi-manager/Source/Cloudflare.cs does: put the object, confirm it
really landed with a HEAD, and purge the CDN for the files that are fetched
without a cache-buster.
"""

import mimetypes
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
import botocore
import requests
from botocore.config import Config

import config
from util import info, warn

mimetypes.add_type("text/plain", ".lua")
mimetypes.add_type("text/plain", ".addon")
mimetypes.add_type("font/ttf", ".ttf")
mimetypes.add_type("font/otf", ".otf")


class R2:
    def __init__(self, endpoint, access_key, secret_key, bucket, dry_run=False):
        self.bucket = bucket
        self.dry_run = dry_run

        # R2 rejects the CRC32 trailers that botocore >= 1.36 adds by default.
        # This is the boto3 equivalent of DisableDefaultChecksumValidation /
        # DisablePayloadSigning on the C# PutObjectRequest.
        self.client = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name="auto",
            config=Config(
                request_checksum_calculation="when_required",
                response_checksum_validation="when_required",
                retries={"max_attempts": 5, "mode": "standard"},
                s3={"addressing_style": "path"},
            ),
        )

    # -- reads ---------------------------------------------------------------

    def get(self, key):
        """Return the object's bytes, or None when it does not exist."""
        try:
            response = self.client.get_object(Bucket=self.bucket, Key=key)
            return response["Body"].read()
        except self.client.exceptions.NoSuchKey:
            return None
        except botocore.exceptions.ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
                return None
            raise

    # -- writes --------------------------------------------------------------

    def put(self, key, data, content_type=None):
        if self.dry_run:
            info(f"    [dry-run] would upload {key} ({len(data)} bytes)")
            return

        if content_type is None:
            content_type = mimetypes.guess_type(key)[0] or "application/octet-stream"

        last = None
        for attempt in range(1, config.UPLOAD_RETRIES + 1):
            try:
                self.client.put_object(
                    Bucket=self.bucket, Key=key, Body=data, ContentType=content_type
                )
                self._verify(key)
                return
            except Exception as exc:  # noqa: BLE001 - retried, then re-raised below
                last = exc
                if attempt < config.UPLOAD_RETRIES:
                    time.sleep(0.25 * (2 ** (attempt - 1)))

        raise RuntimeError(f"Upload failed for {key}: {last}")

    def _verify(self, key):
        """
        HEAD the object after writing it. Mirrors VerifyObjectExists() in the
        manager: a 200 on PUT is not proof the object is readable.
        """
        last = None
        for attempt in range(1, config.VERIFY_RETRIES + 1):
            try:
                self.client.head_object(Bucket=self.bucket, Key=key)
                return
            except Exception as exc:  # noqa: BLE001
                last = exc
                time.sleep(0.25 * attempt)
        raise RuntimeError(f"Upload verification failed for {key}: {last}")

    def put_many(self, items):
        """
        Upload {key: bytes} in parallel. Raises if any single upload fails, so a
        partial batch cannot be mistaken for success.
        """
        if not items:
            return

        if self.dry_run:
            for key in sorted(items):
                info(f"    [dry-run] would upload {key} ({len(items[key])} bytes)")
            return

        failures = []
        done = 0
        total = len(items)

        with ThreadPoolExecutor(max_workers=config.UPLOAD_CONCURRENCY) as pool:
            futures = {pool.submit(self.put, k, v): k for k, v in items.items()}
            for future in as_completed(futures):
                key = futures[future]
                try:
                    future.result()
                    done += 1
                    if done % 25 == 0 or done == total:
                        info(f"    uploaded {done}/{total}")
                except Exception as exc:  # noqa: BLE001
                    failures.append(f"{key}: {exc}")

        if failures:
            for line in failures[:10]:
                warn(f"    upload failure: {line}")
            raise RuntimeError(f"{len(failures)} of {total} uploads failed")


# ---------------------------------------------------------------------------
# CDN cache
# ---------------------------------------------------------------------------


def purge_cache(keys, dry_run=False):
    """
    Purge specific URLs from the Cloudflare edge.

    Only matters for launcher.json and the build manifest. Individual build files
    are fetched as `?v={build.updated}`, so bumping that timestamp is what busts
    their cache. Optional: skipped entirely when the credentials are not set.
    """
    zone = os.environ.get("CLOUDFLARE_ZONE_ID", "").strip()
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "").strip()

    if not zone or not token:
        info("    cache purge skipped (CLOUDFLARE_ZONE_ID / CLOUDFLARE_API_TOKEN not set)")
        return

    urls = [f"{config.PUBLIC_ORIGIN}/{k}" for k in keys]
    if dry_run:
        info(f"    [dry-run] would purge {len(urls)} URL(s)")
        return

    try:
        response = requests.post(
            f"https://api.cloudflare.com/client/v4/zones/{zone}/purge_cache",
            headers={"Authorization": f"Bearer {token}"},
            json={"files": urls},
            timeout=config.HTTP_TIMEOUT,
        )
        if response.ok and response.json().get("success"):
            info(f"    purged {len(urls)} URL(s) from cache")
        else:
            warn(f"    cache purge failed: {response.status_code} {response.text[:300]}")
    except requests.RequestException as exc:
        # Non-fatal. The files are already live; the edge will catch up on TTL.
        warn(f"    cache purge error: {exc}")
