# Reproducible build & test environment: GHC + cabal + JDK (for Jasmin/java) + LLVM (llvm-link/lli).
#
#   docker build -t instant-compiler .                       # builds compilers, runs no tests
#   docker run --rm instant-compiler make test               # unit + end-to-end tests
#   docker run --rm -v "$PWD/progs:/data" instant-compiler sh -c 'insc_jvm /data/prog.ins && java -cp /data prog'
#
# Works the same with podman (replace `docker` with `podman`).

FROM docker.io/library/haskell:9.12-bookworm AS toolchain
RUN apt-get update \
 && apt-get install -y --no-install-recommends default-jdk-headless llvm make \
 && rm -rf /var/lib/apt/lists/*
RUN cabal update

FROM toolchain
WORKDIR /opt/instant
# Dependencies (incl. alex/happy) first, so they are cached between source changes.
COPY instant.cabal ./
RUN cabal build --only-dependencies --enable-tests all
COPY . .
RUN make
ENV PATH=/opt/instant:$PATH
