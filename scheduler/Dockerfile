# Rust version is pinned: Cargo.lock v4 needs >= 1.78, and the locked sqlx 0.5 /
# actix-web 4 beta dependencies may break on arbitrary newer toolchains.
FROM rust:1.85-bullseye AS build

WORKDIR /home/rust/

COPY . .

# sqlx `query!` macros are checked against sqlx-data.json instead of a live
# database, so the image builds without Postgres. Regenerate the file with
# `cargo sqlx prepare --merged -- --all-targets` after changing any query.
ENV SQLX_OFFLINE=true

RUN cargo build --release --bin nettu_scheduler --bin migrate

FROM debian:bullseye-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libssl1.1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /home/rust/

COPY --from=build /home/rust/target/release/nettu_scheduler /home/rust/target/release/migrate ./

EXPOSE 5000

# Migrations are embedded into `migrate` at compile time, so every image
# carries exactly the schema version it expects.
ENTRYPOINT ["/bin/sh", "-c" , "./migrate && ./nettu_scheduler"]
