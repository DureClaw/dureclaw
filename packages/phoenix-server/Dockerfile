# ── Stage 1: Builder ─────────────────────────────────────────────────────────
FROM elixir:1.17-alpine AS builder

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY lib lib
COPY priv priv

RUN mix release harness_server

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM alpine:3.20 AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs bash curl

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/harness_server ./

ENV PORT=4000
ENV HOST=0.0.0.0
ENV OAH_DATA_DIR=/data

EXPOSE 4000

VOLUME ["/data"]

HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -sf http://localhost:$PORT/api/health || exit 1

CMD ["bin/harness_server", "foreground"]
