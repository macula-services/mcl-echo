# mcl-echo
#
# Always-on io.macula.echo, the mesh's hello-world target every SDK quickstart calls
#
# NO DATA VOLUME AS GENERATED. The scaffold writes nothing, and a named volume
# for data that does not exist is a promise the image cannot keep. Add one
# together with the code that writes it, and declare it here and in the compose
# file at the same time.

# ⚠ THE RUNTIME IS PINNED IN TWO PLACES AND THEY MUST AGREE: here and `lint.yml'
# beside it. A generated service that builds on one release and tests on another
# only ever proves "the tests pass on the CI release".
#
# This template said 27 from the beginning and nothing revisited it, so every
# service scaffolded from it inherited 27 while development machines moved on.
# In `hecate-biotope' that cost three commits of red CI on a crash that does not
# occur on the development release at all, and because `build-push.yml' is a
# separate workflow the image shipped to the fleet regardless.
# ⚠ PINNED BY TAG AND DIGEST. `erlang:28-alpine' floats, and when Docker Hub
# moved it on 2026-09-22 the next deploy shipped OTP 28.5 while lint tested
# something else. 28.4.3 is the team standard; the digest is the multi-arch
# index, so a re-pushed tag cannot change what builds. hexpm's image, because
# Docker's own `erlang' publishes no 28.4.3; Alpine 3.22.6, the same release as
# the runtime stage below, whose OpenSSL 3.5 carries ML-DSA. Move both on
# purpose, never by drift.
FROM docker.io/hexpm/erlang:28.4.3-alpine-3.22.6@sha256:3815b99f486c2509baf556045bca0c5fc1c3ee50fb50a80590534f22cb48736c AS builder
WORKDIR /build

# macula ships a QUIC NIF. MACULA_FORCE_SOURCE_BUILD makes it build here rather
# than fetch a prebuilt binary linked against a different libc, which is the
# recorded glibc trap: the fetched artifact loads on the build host and fails on
# alpine at runtime.
#
# openssl-dev/zstd-dev/snappy-dev/lz4-dev: mcl_om pulls in rocksdb (via
# barrel_docdb) and khepri/ra transitively, UNCONDITIONALLY -- confirmed on a
# storeless, producer-only service (no store_id/0 or data_dir/0 exported),
# which still failed to build without these. Not specific to a service that
# owns its own reckon-db store.
RUN apk add --no-cache git curl bash build-base cmake perl linux-headers \
        openssl-dev zstd-dev snappy-dev lz4-dev
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTFLAGS="-C target-feature=-crt-static"
ENV MACULA_FORCE_SOURCE_BUILD=1

# rebar3 pinned to a release and its sha256, the same one mcl-om's scaffold
# installs: the S3 URL this used serves whatever was published last.
RUN curl -fsSL https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 \
        -o /usr/local/bin/rebar3 \
    && echo "af85aab41f9fd74bdd6341ebdf6fe9c88077aab9f8eac82371583fa02f2b0bdf  /usr/local/bin/rebar3" \
        | sha256sum -c - \
    && chmod +x /usr/local/bin/rebar3

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/ and the Rust toolchain is not re-run per commit.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM docker.io/alpine:3.22
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-echo"
# zstd-libs/snappy/lz4-libs: the RUNTIME shared libraries for rocksdb's
# compression backends, compiled against in the builder stage above via
# their -dev packages. Missing here crashes the release outright on
# boot -- rocksdb's on_load NIF init fails with "Failed to load NIF
# library: Error loading shared library liblz4.so.1: No such file or
# directory" and the whole node exits, since kernel can't start.
# Confirmed live: this stage shipped without them once already.
RUN apk add --no-cache ncurses-libs libstdc++ libgcc openssl ca-certificates curl \
        zstd-libs snappy lz4-libs
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/mcl_echo ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV MCL_NODE_NAME=mcl_echo
ENV MCL_NODE_HOST=127.0.0.1
ENV MCL_COOKIE=mcl_echo
ENV MCL_HEALTH_PORT=8461

VOLUME ["/etc/mcl/secrets"]

EXPOSE 8461
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MCL_HEALTH_PORT}/health" || exit 1

CMD ["/app/bin/mcl_echo", "foreground"]
