# ---- Builder stage: clones gno source, builds gnoland, gnokms, and gnokey binaries
FROM golang:1.24-bookworm AS builder

ARG GNO_VERSION=master

RUN apt-get update && apt-get install -y --no-install-recommends \
  git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/gnolang/gno.git /gno && \
  git -C /gno checkout ${GNO_VERSION}

WORKDIR /gno

RUN go build -o /usr/local/bin/gnoland ./gno.land/cmd/gnoland
RUN go build -C ./contribs/gnokms -o /usr/local/bin/gnokms .
RUN go build -o /usr/local/bin/gnokey ./gno.land/cmd/gnokey

# ---- gnoland final stage
FROM debian:bookworm-slim AS gnoland

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/gnoland /usr/local/bin/gnoland

# ---- gnokms final stage
FROM debian:bookworm-slim AS gnokms

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/gnokms /usr/local/bin/gnokms
COPY --from=builder /usr/local/bin/gnokey /usr/local/bin/gnokey
COPY docker/gnokms-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
