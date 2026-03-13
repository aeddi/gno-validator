# ---- Builder stage: clones gno@master, builds all binaries + genesis tools
FROM golang:1.24-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl jq python3 gzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth=1 https://github.com/gnolang/gno.git /gno

WORKDIR /gno

RUN go build -o /usr/local/bin/gnoland ./gno.land/cmd/gnoland
RUN go build -C ./contribs/gnokms -o /usr/local/bin/gnokms .

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
