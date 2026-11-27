# linux/amd64 manifests for Hex Bob 1.20.5/29.1.2 and Debian trixie-20261123-slim.
FROM hexpm/elixir@sha256:33757b440834115418d681f2260e8967abfa5fc08edec090edd2c6e4fbfde27c AS compile

RUN sed -i \
      -e 's|http://deb.debian.org/debian-security|https://snapshot.debian.org/archive/debian-security/20261123T000000Z|' \
      -e 's|http://deb.debian.org/debian$|https://snapshot.debian.org/archive/debian/20261123T000000Z|' \
      /etc/apt/sources.list.d/debian.sources \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install -y --no-install-recommends build-essential curl git \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod ELIXIR_ERL_OPTIONS="+S 4"
# C toolchains use this fixed epoch for build-time macros in native dependencies.
ENV SOURCE_DATE_EPOCH=1795392000
WORKDIR /app
COPY .tool-versions mix.exs mix.lock ./
RUN test "$(cat /usr/local/lib/erlang/releases/29/OTP_VERSION)" = "$(awk '$1 == "erlang" {print $2}' .tool-versions)" \
    && test "$(elixir -e 'IO.write(System.version())')" = "$(awk '$1 == "elixir" {sub(/-otp-29$/, "", $2); print $2}' .tool-versions)" \
    && curl -fsSL https://codeload.github.com/hexpm/hex/tar.gz/edec2dda0968d5a6babd202bad17fcea2d1640bb -o /tmp/hex.tar.gz \
    && echo 'db1de53b9e17389d6130eb48df13745220282cfb02d4141065d9c4f7c7522fcd  /tmp/hex.tar.gz' | sha256sum -c \
    && mkdir /tmp/hex && tar -xzf /tmp/hex.tar.gz -C /tmp/hex --strip-components=1 \
    && (cd /tmp/hex && mix archive.build && mix archive.install ./hex-2.6.0.ez --force) \
    && curl -fsSL https://github.com/erlang/rebar3/releases/download/3.28.0/rebar3 -o /tmp/rebar3 \
    && echo '5a28b1cca082d3b023ec0f5df9d9f9d52557036c6f2a21c1ffa11b93a984dd42  /tmp/rebar3' | sha256sum -c \
    && mix local.rebar rebar3 /tmp/rebar3 --force
COPY config/config.exs config/config.exs
# Remove the normalization when the locked upstream Xema release provides
# deterministic keyword ordering and two clean builds match without it.
COPY rel/build/normalize_xema.sh /tmp/normalize_xema.sh
RUN mix deps.get --only prod --check-locked \
    && sh /tmp/normalize_xema.sh deps/xema/lib/xema/json_schema.ex \
    && mix deps.compile

COPY lib lib
COPY priv priv
COPY config/runtime.exs config/runtime.exs
COPY rel rel
# Git records the executable bit, while checkout umasks can vary.
RUN find config lib priv rel -type d -exec chmod 0755 {} + \
    && find config lib priv rel -type f -exec chmod 0644 {} + \
    && chmod 0755 rel/overlays/bin/server rel/overlays/bin/migrate \
    && mix compile --force --warnings-as-errors

FROM compile AS builder
RUN mix release voelgoed_ai

FROM debian@sha256:ab3b3c8c5159eebfca4376430132d53c4d425f869c765ecbe47177a030da575d
COPY --from=compile /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/debian.sources
RUN --mount=type=bind,from=compile,source=/etc/ssl/certs/ca-certificates.crt,target=/tmp/debian-ca.pem \
    apt-get -o Acquire::https::CaInfo=/tmp/debian-ca.pem -o Acquire::Check-Valid-Until=false update \
    && apt-get -o Acquire::https::CaInfo=/tmp/debian-ca.pem install -y --no-install-recommends \
      ca-certificates libsctp1 libssl3t64 libstdc++6 libtinfo6 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 RELEASE_TMP=/tmp/voelgoed-ai
WORKDIR /app
COPY --from=builder /app/_build/prod/rel/voelgoed_ai ./
COPY --from=compile /usr/local/lib/erlang/releases/29/OTP_VERSION /app/releases/OTP_VERSION
USER 65534:65534
EXPOSE 4000
CMD ["/app/bin/server"]
