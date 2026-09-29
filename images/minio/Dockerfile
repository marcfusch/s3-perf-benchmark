# MinIO no longer publishes container images, so it is built from the last
# upstream release tag of the (now archived) repository.
FROM golang:1.24-alpine AS build
ARG MINIO_TAG=RELEASE.2025-10-15T17-29-55Z
RUN apk add --no-cache git make bash
RUN git clone --depth 1 --branch ${MINIO_TAG} https://github.com/minio/minio /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -trimpath -tags kqueue -ldflags "-s -w" -o /minio .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates curl
COPY --from=build /minio /usr/bin/minio
ENTRYPOINT ["/usr/bin/minio"]
