FROM swift:6.2-jammy AS build

# Ubuntu's libsqlite3-dev is built without SQLITE_ENABLE_SNAPSHOT, which GRDB.swift requires
# (DatabaseSnapshotPool / WALSnapshot reference sqlite3_snapshot_* symbols). Build SQLite
# from source with the required flags, install to /usr/local, replacing the system one.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential wget ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ARG SQLITE_VERSION=sqlite-autoconf-3460100
ARG SQLITE_URL=https://www.sqlite.org/2024/${SQLITE_VERSION}.tar.gz
RUN cd /tmp \
 && wget -q "$SQLITE_URL" \
 && tar -xzf ${SQLITE_VERSION}.tar.gz \
 && cd ${SQLITE_VERSION} \
 && CFLAGS="-DSQLITE_ENABLE_SNAPSHOT=1 -DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_RTREE=1 -DSQLITE_ENABLE_COLUMN_METADATA=1 -O2 -fPIC" \
    ./configure --prefix=/usr/local \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig \
 && cd / && rm -rf /tmp/${SQLITE_VERSION}*

WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources Sources
COPY Tests Tests
# Point the compiler/linker at the custom SQLite first (/usr/local/{include,lib}).
RUN swift build -c release --static-swift-stdlib --product memory-service \
    -Xcc -I/usr/local/include \
    -Xlinker -L/usr/local/lib \
    -Xlinker -rpath -Xlinker /usr/local/lib

FROM swift:6.2-jammy-slim AS runtime
# tzdata: named zones (e.g. America/Havana via the TZ env) must resolve so the agent's clock
# (AgentPrompt.nowContext) and schedule ISO↔epoch conversions use local time, not the container's UTC.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*
# Bring the custom SQLite shared lib along; the binary's rpath points at /usr/local/lib.
COPY --from=build /usr/local/lib/libsqlite3.so* /usr/local/lib/
RUN ldconfig
WORKDIR /app
COPY --from=build /src/.build/release/memory-service /app/memory-service
EXPOSE 8081
ENTRYPOINT ["/app/memory-service"]
