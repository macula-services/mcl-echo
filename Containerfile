# mcl-echo
#
# Always-on io.macula.echo, the mesh's hello-world target every SDK quickstart calls
#
# NO DATA VOLUME AS GENERATED. The scaffold writes nothing, and a named volume
# for data that does not exist is a promise the image cannot keep. Add one
# together with the code that writes it, and declare it here and in the compose
# file at the same time.

# ⚠ THE TOOLCHAIN IS PINNED IN TWO PLACES AND THEY MUST AGREE: here and
# `lint.yml' beside it. A service that builds on one toolchain and tests on
# another only ever proves "the tests pass on the CI toolchain".
#
# The team's image pair, pinned by dated tag AND digest so neither can drift:
# macula-ci-otp builds (OTP 28.4.3, the team standard, OpenSSL 3.5 with ML-DSA,
# rebar3 3.27.0, Rust for macula's NIFs, all pinned), macula-pq-runtime runs
# (Debian trixie, the same OpenSSL, the runtime libraries a release links). Both
# are glibc, so macula's NIFs build and load on the same libc. This replaced
# hexpm/erlang alpine plus alpine:3.22 on 2026-09-26, the last mcl service on that
# pair besides mcl-graph.
FROM ghcr.io/macula-io/macula-ci-otp:20260923-1444@sha256:dd2ba6eb858a0eacedf0179300323fe5c6da46fb308d22da0ca8cfcd1f0718dc AS builder

# Refuse to build on anything but the team standard with ML-DSA: a base moved
# under the digest would otherwise build quietly on another OTP.
RUN erl -noshell -eval ' \
    Otp = string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])))), \
    Mldsa = lists:member(mldsa87, crypto:supports(public_keys)), \
    io:format("OTP ~s, mldsa87 ~p~n", [Otp, Mldsa]), \
    case {Otp, Mldsa} of \
        {<<"28.4.3">>, true} -> halt(0); \
        _                    -> halt(1) \
    end.'

WORKDIR /build

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM ghcr.io/macula-io/macula-pq-runtime:20260923-1444@sha256:15a5501b7277804c5a62c93121d157773d1401d238a1bf630ef4b50fc2f1df09
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-echo"
# The commit this image was built from (build-push passes github.sha), so a
# digest pinned on a box traces back to a commit.
ARG REVISION=unknown
LABEL org.opencontainers.image.revision="${REVISION}"
# NO EXTRA PACKAGES. The alpine stage this replaced installed ncurses-libs,
# libstdc++, libgcc, openssl, ca-certificates, curl, zstd-libs, snappy and
# lz4-libs. The runtime image carries every one of them (libncurses6/libtinfo6,
# libstdc++6, libgcc-s1, openssl and libssl3 3.5, ca-certificates, curl for the
# health check, libzstd1, liblz4-1) except snappy, which only rocksdb's NIF
# linked: mcl_om stopped bringing rocksdb in 0.27, and no .so in this release
# links it (ldd, 2026-09-26).
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
