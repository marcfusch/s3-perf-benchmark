#!/usr/bin/env python3
"""Writes a fixed data set and checks it back, for the node kill campaigns.

  write: N objects of fresh random data, with their SHA256 in a manifest;
  check: reads every object of the manifest and reports how many are
         missing or corrupted (the reliability criterion of the proposal).

usage: preload.py write|check --hosts h1:p,h2:p --bucket durable
                  --manifest m.json [--objects 500] [--size 1048576]
"""
import argparse
import hashlib
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config


def clients(a):
    return [boto3.client(
        "s3", endpoint_url=f"http://{h}", aws_access_key_id=os.environ["S3_ACCESS_KEY"],
        aws_secret_access_key=os.environ["S3_SECRET_KEY"],
        region_name=os.environ.get("S3_REGION", "us-east-1"),
        config=Config(s3={"addressing_style": "path", "payload_signing_enabled": True},
                      request_checksum_calculation="when_required",
                      response_checksum_validation="when_required",
                      retries={"max_attempts": 3}, max_pool_connections=16))
        for h in a.hosts.split(",")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["write", "check"])
    ap.add_argument("--hosts", required=True)
    ap.add_argument("--bucket", default="durable")
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--objects", type=int, default=500)
    ap.add_argument("--size", type=int, default=1 << 20)
    a = ap.parse_args()
    cs = clients(a)
    t0 = time.time()

    if a.mode == "write":
        try:
            cs[0].create_bucket(Bucket=a.bucket)
        except Exception as e:
            if "BucketAlready" not in str(e):
                raise
        # on a brand new Garage cluster a new bucket is not visible on every
        # node right away: wait until each endpoint sees it
        for c in cs:
            for _ in range(60):
                try:
                    c.head_bucket(Bucket=a.bucket)
                    break
                except Exception:
                    time.sleep(1)

        def put(i):
            data = os.urandom(a.size)
            cs[i % len(cs)].put_object(Bucket=a.bucket, Key=f"obj/{i:06d}", Body=data)
            return f"obj/{i:06d}", hashlib.sha256(data).hexdigest()

        with ThreadPoolExecutor(8) as ex:
            manifest = dict(ex.map(put, range(a.objects)))
        json.dump(manifest, open(a.manifest, "w"))
        res = {"mode": "write", "objects": len(manifest), "seconds": time.time() - t0}
    else:
        manifest = json.load(open(a.manifest))

        def get(item):
            i, (k, h) = item
            try:
                d = cs[i % len(cs)].get_object(Bucket=a.bucket, Key=k)["Body"].read()
                return "ok" if hashlib.sha256(d).hexdigest() == h else "corrupt"
            except Exception:
                return "missing"

        with ThreadPoolExecutor(8) as ex:
            out = list(ex.map(get, enumerate(manifest.items())))
        res = {"mode": "check", "objects": len(out), "ok": out.count("ok"),
               "corrupt": out.count("corrupt"), "missing": out.count("missing"),
               "seconds": time.time() - t0}
    print(json.dumps(res))
    return 0 if res.get("missing", 0) == 0 and res.get("corrupt", 0) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
