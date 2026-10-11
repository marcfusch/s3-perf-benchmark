# Helper image used to apply limits (tc, cgroup files), sample node
# resources, calibrate the limits (fio, stress-ng, iperf3) and run the
# second S3 client used to cross check warp.
FROM alpine:3.22
RUN apk add --no-cache bash coreutils util-linux iproute2 iputils fio stress-ng iperf3 \
    python3 py3-boto3 py3-zstandard py3-matplotlib py3-numpy jq
COPY s3load.py sample.py uniqueness.py /usr/local/bin/
ENTRYPOINT []
