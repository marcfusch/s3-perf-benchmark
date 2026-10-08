#!/usr/bin/env python3
"""Checks that the objects written by a load generator are really distinct.

Systems that deduplicate or compress (Garage does both, per block of 1 MiB)
store far less than systems that do not when the client sends repeated
data, which would bias the comparison. Reads up to --max objects from a
bucket and counts distinct objects, 1 MiB blocks and 16 KiB chunks.

usage: uniqueness.py --host garage-node1:3900 --bucket bench [--max 100]
"""
import argparse
import collections
import hashlib
import json
import os

import boto3
from botocore.config import Config


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--max", type=int, default=100)
    a = ap.parse_args()
    c = boto3.client("s3", endpoint_url=f"http://{a.host}",
                     aws_access_key_id=os.environ["S3_ACCESS_KEY"],
                     aws_secret_access_key=os.environ["S3_SECRET_KEY"],
                     region_name=os.environ.get("S3_REGION", "us-east-1"),
                     config=Config(s3={"addressing_style": "path"}))
    keys = []
    for page in c.get_paginator("list_objects_v2").paginate(Bucket=a.bucket):
        keys += [o["Key"] for o in page.get("Contents", [])]
        if len(keys) >= a.max:
            break
    counts = {n: collections.Counter() for n in ("object", "block_1MiB", "chunk_16KiB")}
    for k in keys[:a.max]:
        d = c.get_object(Bucket=a.bucket, Key=k)["Body"].read()
        counts["object"][hashlib.sha256(d).digest()] += 1
        for name, step in (("block_1MiB", 1 << 20), ("chunk_16KiB", 1 << 14)):
            for i in range(0, len(d), step):
                counts[name][hashlib.sha256(d[i:i + step]).digest()] += 1
    res = {n: {"total": sum(v.values()), "distinct": len(v)} for n, v in counts.items()}
    print(json.dumps(res))


if __name__ == "__main__":
    main()
