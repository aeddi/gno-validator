# ----- Builder stage: clones gno source, builds gnoland, gnokms, and gnokey binaries
FROM    golang:1.24-alpine AS builder
ENV     GNOROOT="/gnoroot"
ARG     GNO_VERSION=master
ARG     GNO_REPO=gnolang/gno
# GNO_COMMIT_HASH pins the exact commit; changing it busts the cache for all downstream layers
ARG     GNO_COMMIT_HASH

RUN     apk add --no-cache git ca-certificates
RUN     git clone https://github.com/${GNO_REPO}.git /gnoroot && \
        git -C /gnoroot checkout ${GNO_COMMIT_HASH:-${GNO_VERSION}}

WORKDIR /gnoroot

RUN     go build -o /usr/local/bin/gnoland ./gno.land/cmd/gnoland
RUN     go build -C ./contribs/gnokms -o /usr/local/bin/gnokms .
RUN     go build -o /usr/local/bin/gnokey ./gno.land/cmd/gnokey

# ----- gnoland final stage
FROM    alpine:3 AS gnoland
ENV     GNOROOT="/gnoroot"
ARG     GNO_COMMIT_HASH
ARG     GNO_VERSION=master
ARG     GNO_REPO=gnolang/gno
ARG     BUILD_DATE
LABEL   gno.commit="${GNO_COMMIT_HASH}" \
        gno.version="${GNO_VERSION}" \
        gno.repo="${GNO_REPO}" \
        build.date="${BUILD_DATE}"

RUN     apk add --no-cache ca-certificates

WORKDIR /gnoroot

COPY    --from=builder /usr/local/bin/gnoland /usr/local/bin/gnoland
COPY    --from=builder /gnoroot/gnovm/stdlibs /gnoroot/gnovm/stdlibs
COPY    --from=builder /gnoroot/gnovm/tests/stdlibs /gnoroot/gnovm/tests/stdlibs

COPY    docker/gnoland-entrypoint.sh /entrypoint.sh
COPY    docker/apply-overrides.sh /apply-overrides.sh
RUN     chmod +x /entrypoint.sh /apply-overrides.sh

ENTRYPOINT ["/entrypoint.sh"]

# ----- gnokms final stage
FROM    alpine:3 AS gnokms
ARG     GNO_COMMIT_HASH
ARG     GNO_VERSION=master
ARG     GNO_REPO=gnolang/gno
ARG     BUILD_DATE
LABEL   gno.commit="${GNO_COMMIT_HASH}" \
        gno.version="${GNO_VERSION}" \
        gno.repo="${GNO_REPO}" \
        build.date="${BUILD_DATE}"

RUN     apk add --no-cache ca-certificates

COPY    --from=builder /usr/local/bin/gnokms /usr/local/bin/gnokms
COPY    --from=builder /usr/local/bin/gnokey /usr/local/bin/gnokey

COPY    docker/gnokms-entrypoint.sh /entrypoint.sh
RUN     chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
