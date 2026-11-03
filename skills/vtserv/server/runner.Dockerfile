# vt-runner — the image every `vt` run's commands execute in (KAN-387).
#
# Ruby for parsalytics, Node + pnpm for investviews/web, Chromium's system libraries for Playwright,
# and the database clients the suites call (psql/pg_isready, redis-server for bin/rspec-full's
# private Redis, redis-cli). No source code and no secret goes into the image: the build context is
# an empty directory, and the checkout is bind-mounted at run time.
#
# vt-remote tags it vt-runner:r<ruby>-n<node>-<sha8 of this file>, so a new Ruby or Node version in
# a branch, or an edit here, builds a new image on first use.
ARG RUBY_VERSION=4.0.9
FROM ruby:${RUBY_VERSION}-bookworm

ARG NODE_VERSION=24.22.1
# Only for `playwright install-deps` (system libraries). The browser itself is installed at run
# time by the checkout's own Playwright version, into a cache volume.
ARG PLAYWRIGHT_VERSION=1.62.1
ARG PG_MAJOR=16
ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsof procps rsync git tini cmake libpq-dev xz-utils \
      redis-server redis-tools sqlite3; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}"; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE; \
    corepack enable; \
    node --version

RUN set -eux; \
    npx -y "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium; \
    rm -rf /var/lib/apt/lists/* /root/.npm

# Caches live in named volumes shared by every run (see compose.yml).
ENV BUNDLE_PATH=/cache/bundle \
    BUNDLE_SILENCE_ROOT_WARNING=1 \
    COREPACK_HOME=/cache/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    PLAYWRIGHT_BROWSERS_PATH=/cache/ms-playwright \
    NEXT_TELEMETRY_DISABLED=1

# A login shell (`bash -lc`, which e2e-live.sh uses for every Rails command) resets PATH from
# /etc/profile on Debian. Keep the image's gem binaries on it.
RUN printf 'export PATH="/usr/local/bundle/bin:$PATH"\n' > /etc/profile.d/vt-path.sh
