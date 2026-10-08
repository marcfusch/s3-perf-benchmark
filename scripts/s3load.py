#!/usr/bin/env python3
"""Minimal independent S3 load generator, used only to cross check warp.

It is not tied to any storage vendor (boto3, the AWS SDK). Same idea as warp:
N workers, fixed object size, fixed duration, requests spread round robin
over the endpoints. Phase "put" writes objects, phase "get" reads back the
objects written by the put phase.

usage: s3load.py --hosts h1:p,h2:p,h3:p --size 1048576 --concurrent 8
                 --duration 30 --op put|get [--objects 300] --out result.json
"""
import argparse
import itertools
import json
import os
import statistics
import threading
import time

import boto3
from botocore.config import Config


def client(host, a):
    return boto3.client(
        "s3", endpoint_url=f"http://{host}", aws_access_key_id=a.access_key,
        aws_secret_access_key=a.secret_key, region_name=a.region,
        # same request shape as warp: SHA256 signed payload and no extra
        # CRC checksum, recent botocore otherwise skips the payload hash,
        # which is cheaper for servers that verify it (Garage is CPU bound)
        config=Config(s3={"addressing_style": "path", "payload_signing_enabled": True},
                      request_checksum_calculation="when_required",
                      response_checksum_validation="when_required",
                      retries={"max_attempts": 1}, max_pool_connections=a.concurrent))


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    i = min(len(sorted_vals) - 1, int(round(p / 100 * (len(sorted_vals) - 1))))
    return sorted_vals[i]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hosts", required=True)
    ap.add_argument("--access-key", default=os.environ.get("S3_ACCESS_KEY"))
    ap.add_argument("--secret-key", default=os.environ.get("S3_SECRET_KEY"))
    ap.add_argument("--region", default=os.environ.get("S3_REGION", "us-east-1"))
    ap.add_argument("--bucket", default="s3load")
    ap.add_argument("--size", type=int, default=1 << 20)
    ap.add_argument("--concurrent", type=int, default=8)
    ap.add_argument("--duration", type=float, default=30)
    ap.add_argument("--op", choices=["put", "get"], required=True)
    ap.add_argument("--objects", type=int, default=300,
                    help="get: read only the first N objects, like warp get --objects")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    hosts = a.hosts.split(",")
    clients = [client(h, a) for h in hosts]
    if a.op == "put":
        try:
            clients[0].create_bucket(Bucket=a.bucket)
        except clients[0].exceptions.BucketAlreadyOwnedByYou:
            pass
        except Exception as e:  # some servers answer differently when it exists
            if "BucketAlready" not in str(e):
                raise
        keys = None
    else:
        keys = []
        pag = clients[0].get_paginator("list_objects_v2")
        for page in pag.paginate(Bucket=a.bucket):
            keys += [o["Key"] for o in page.get("Contents", [])]
        if not keys:
            raise SystemExit("no object to read, run the put phase first")
        keys = sorted(keys)[:a.objects]

    rr = itertools.count()
    lock = threading.Lock()
    lat, errors, nbytes = [], [0], [0]
    deadline = time.monotonic() + a.duration

    def worker(w):
        n = 0
        while time.monotonic() < deadline:
            i = next(rr)
            c = clients[i % len(clients)]
            t0 = time.perf_counter()
            try:
                if a.op == "put":
                    # fresh random data for every object, generated before the timer
                    # starts: repeated payloads would be deduplicated by Garage
                    payload = os.urandom(a.size)
                    t0 = time.perf_counter()
                    c.put_object(Bucket=a.bucket, Key=f"w{w}/o{n}", Body=payload)
                    got = a.size
                else:
                    got = len(c.get_object(Bucket=a.bucket, Key=keys[i % len(keys)])["Body"].read())
                dt = time.perf_counter() - t0
                with lock:
                    lat.append(dt)
                    nbytes[0] += got
            except Exception:
                with lock:
                    errors[0] += 1
            n += 1

    t_start = time.monotonic()
    ths = [threading.Thread(target=worker, args=(w,)) for w in range(a.concurrent)]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    elapsed = time.monotonic() - t_start

    lat.sort()
    res = {
        "op": a.op, "size": a.size, "concurrent": a.concurrent, "elapsed_s": elapsed,
        "requests": len(lat), "errors": errors[0],
        "throughput_mib_s": nbytes[0] / elapsed / 2**20,
        "ops_s": len(lat) / elapsed,
        "lat_ms": {"p50": pct(lat, 50) * 1e3, "p90": pct(lat, 90) * 1e3,
                   "p99": pct(lat, 99) * 1e3, "mean": statistics.fmean(lat) * 1e3} if lat else None,
    }
    with open(a.out, "w") as f:
        json.dump(res, f, indent=1)
    print(json.dumps(res))


if __name__ == "__main__":
    main()
