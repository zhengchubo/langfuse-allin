FROM --platform=${TARGETPLATFORM:-linux/amd64} node:20-alpine AS alpine

# It's important to update the index before installing packages to ensure you're getting the latest versions.
# Check https://github.com/nodejs/docker-node/tree/b4117f9333da4138b03a546ec926ef50a31506c3#nodealpine to understand why libc6-compat might be needed.
RUN apk update && apk upgrade --no-cache libcrypto3 libssl3 libc6-compat busybox ssl_client


FROM --platform=${TARGETPLATFORM:-linux/amd64} alpine AS base
RUN npm config set registry https://registry.npmmirror.com
RUN npm install turbo@^2.5.5 --global
RUN npm install -g --no-package-lock --no-save prisma@6.10.1
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable
#RUN corepack install -g pnpm@10.14.0
RUN corepack prepare pnpm@9.5.0 --activate

FROM --platform=${TARGETPLATFORM:-linux/amd64} base AS pruner

WORKDIR /app

COPY . .
RUN turbo prune --scope=worker --docker


FROM --platform=${TARGETPLATFORM:-linux/amd64} base AS pruner2
WORKDIR /app
COPY . .
RUN turbo prune --scope=web --docker


FROM --platform=${TARGETPLATFORM:-linux/amd64} base AS builder
WORKDIR /app

# First install the dependencies (as they change less often)
COPY --from=pruner /app/out/pnpm-lock.yaml ./pnpm-lock.yaml
COPY --from=pruner /app/out/pnpm-workspace.yaml ./pnpm-workspace.yaml
COPY --from=pruner /app/out/json/ .

RUN npm config set registry https://registry.npmmirror.com
RUN pnpm install --frozen-lockfile

# pass public variables in build step
ARG NEXT_PUBLIC_LANGFUSE_CLOUD_REGION
ARG NEXT_PUBLIC_DEMO_ORG_ID
ARG NEXT_PUBLIC_DEMO_PROJECT_ID
ARG NEXT_PUBLIC_POSTHOG_KEY
ARG NEXT_PUBLIC_POSTHOG_HOST

# Copy source code of isolated subworkspace
COPY --from=pruner /app/out/full/ .
RUN turbo run build --filter=worker...


FROM --platform=${TARGETPLATFORM:-linux/amd64} base AS builder2
WORKDIR /app

# First install the dependencies (as they change less often)
COPY --from=pruner2 /app/out/pnpm-lock.yaml ./pnpm-lock.yaml
COPY --from=pruner2 /app/out/pnpm-workspace.yaml ./pnpm-workspace.yaml
COPY --from=pruner2 /app/out/json/ .
RUN npm config set registry https://registry.npmmirror.com
RUN pnpm install --frozen-lockfile

ENV DOCKER_BUILD 1
ENV NEXT_MANUAL_SIG_HANDLE true

# pass public variables in build step
ARG NEXT_PUBLIC_PLAIN_APP_ID
ARG NEXT_PUBLIC_LANGFUSE_CLOUD_REGION
ENV NEXT_PUBLIC_LANGFUSE_CLOUD_REGION=$NEXT_PUBLIC_LANGFUSE_CLOUD_REGION
ARG NEXT_PUBLIC_DEMO_ORG_ID
ENV NEXT_PUBLIC_DEMO_ORG_ID=$NEXT_PUBLIC_DEMO_ORG_ID
ARG NEXT_PUBLIC_DEMO_PROJECT_ID
ENV NEXT_PUBLIC_DEMO_PROJECT_ID=$NEXT_PUBLIC_DEMO_PROJECT_ID
ARG NEXT_PUBLIC_SIGN_UP_DISABLED
ENV NEXT_PUBLIC_SIGN_UP_DISABLED=$NEXT_PUBLIC_SIGN_UP_DISABLED
ARG NEXT_PUBLIC_TURNSTILE_SITE_KEY
ENV NEXT_PUBLIC_TURNSTILE_SITE_KEY=$NEXT_PUBLIC_TURNSTILE_SITE_KEY
ARG NEXT_PUBLIC_POSTHOG_KEY
ENV NEXT_PUBLIC_POSTHOG_KEY=$NEXT_PUBLIC_POSTHOG_KEY
ARG NEXT_PUBLIC_POSTHOG_HOST
ENV NEXT_PUBLIC_POSTHOG_HOST=$NEXT_PUBLIC_POSTHOG_HOST
ARG NEXT_PUBLIC_LANGFUSE_TRACING_SAMPLE_RATE
ENV NEXT_PUBLIC_LANGFUSE_TRACING_SAMPLE_RATE=$NEXT_PUBLIC_LANGFUSE_TRACING_SAMPLE_RATE
ARG NEXT_PUBLIC_SENTRY_ENVIRONMENT
ENV NEXT_PUBLIC_SENTRY_ENVIRONMENT=$NEXT_PUBLIC_SENTRY_ENVIRONMENT
ARG NEXT_PUBLIC_SENTRY_DSN
ENV NEXT_PUBLIC_SENTRY_DSN=$NEXT_PUBLIC_SENTRY_DSN
ARG NEXT_PUBLIC_BASE_PATH
ENV NEXT_PUBLIC_BASE_PATH=$NEXT_PUBLIC_BASE_PATH

# Sentry already needs to be set on build time to upload sourcemaps
# This must not be set for OSS releases as we would share our Sentry secret.
ARG SENTRY_AUTH_TOKEN
ENV SENTRY_AUTH_TOKEN=$SENTRY_AUTH_TOKEN
ARG SENTRY_ORG
ENV SENTRY_ORG=$SENTRY_ORG
ARG SENTRY_PROJECT
ENV SENTRY_PROJECT=$SENTRY_PROJECT

# Accept build id as NEXT_PUBLIC_BUILD_ID
ARG NEXT_PUBLIC_BUILD_ID
ENV NEXT_PUBLIC_BUILD_ID=$NEXT_PUBLIC_BUILD_ID
ENV SENTRY_RELEASE=$NEXT_PUBLIC_BUILD_ID

# Copy source code of isolated subworkspace
COPY --from=pruner2 /app/out/full/ .

# remove middleware.ts if it exists - not needed in self-hosted environments
RUN rm -f ./web/src/middleware.ts

# Next.js collects completely anonymous telemetry data about general usage.
# Learn more here: https://nextjs.org/telemetry
# Uncomment the following line in case you want to disable telemetry during the build.
ENV NEXT_TELEMETRY_DISABLED 1
ENV NEXT_MANUAL_SIG_HANDLE true
# set the CI flag to true to get CI specific logs
ENV CI true

RUN NODE_OPTIONS='--max-old-space-size=8192' turbo run build --filter=web...


#FROM --platform=${TARGETPLATFORM:-linux/amd64} base AS runner
FROM clickhouse/clickhouse-server:25.7-alpine AS runner

ARG TARGETPLATFORM
ARG BUILDPLATFORM

ARG NEXT_PUBLIC_BUILD_ID
ENV BUILD_ID=$NEXT_PUBLIC_BUILD_ID
ARG NEXT_PUBLIC_LANGFUSE_CLOUD_REGION
ENV NEXT_PUBLIC_LANGFUSE_CLOUD_REGION=$NEXT_PUBLIC_LANGFUSE_CLOUD_REGION
ENV NODE_ENV production
# Uncomment the following line in case you want to disable telemetry during runtime.
ENV NEXT_TELEMETRY_DISABLED 1
# Needed to re-enable validation of environment variables during runtime
ENV DOCKER_BUILD 0
# Set NEXT_MANUAL_SIG_HANDLE for runtime
ENV NEXT_MANUAL_SIG_HANDLE true
ENV NODE_ENV=production

RUN sed -i 's#https\?://dl-cdn.alpinelinux.org/alpine#https://mirrors.tuna.tsinghua.edu.cn/alpine#g' /etc/apk/repositories
RUN apk update
RUN apk upgrade
RUN apk add --no-cache --update dumb-init su-exec tzdata \
    supervisor redis minio postgresql \
    sudo bash curl git icu-data-full \
    nodejs \
    npm \
    python3 \
    make openssl \
    g++ \
    vips-dev \
    build-base

# prepare postgres
RUN mkdir -p /var/lib/postgresql/data && \
    mkdir -p /run/postgresql && \
    chown postgres:postgres /run/postgresql && \
    chmod 775 /run/postgresql && \
    chown -R postgres:postgres /var/lib/postgresql

# prepare clickhouse
RUN mkdir -p /data
WORKDIR /app

# Don't run production as root
ARG UID=1001
ARG GID=1001
RUN addgroup --system --gid ${GID} expressjs
RUN adduser --system --uid ${UID} expressjs
RUN npm config set registry https://registry.npmmirror.com
RUN npm install -g yarn@berry
RUN npm install -g --no-package-lock --no-save prisma@6.10.1

# Install dd-trace only if NEXT_PUBLIC_LANGFUSE_CLOUD_REGION is configured
ARG NEXT_PUBLIC_LANGFUSE_CLOUD_REGION
RUN if [ -n "$NEXT_PUBLIC_LANGFUSE_CLOUD_REGION" ]; then \
        npm install --no-package-lock --no-save dd-trace@5.36.0; \
    fi

COPY docker/migrate .
RUN MIGRATE_TARGET_ARCH=$(echo ${TARGETPLATFORM:-linux/amd64} | sed 's/\//-/g') && \
#    wget -q -O- https://github.com/golang-migrate/migrate/releases/download/v4.18.3/migrate.$MIGRATE_TARGET_ARCH.tar.gz | tar xvz && \
    mv migrate /usr/bin/migrate
# 复制Supervisor配置
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh .
RUN chmod +x ./entrypoint.sh /usr/bin/migrate
RUN mkdir -p /app/log/
RUN chown -R expressjs:expressjs /app

USER expressjs
COPY --from=builder --chown=expressjs:expressjs /app .

COPY --from=builder2 --chown=expressjs:expressjs /app/web/next.config.mjs .
COPY --from=builder2 --chown=expressjs:expressjs /app/web/package.json .

# Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing
COPY --from=builder2 --chown=expressjs:expressjs /app/web/.next/standalone ./
COPY --from=builder2 --chown=expressjs:expressjs /app/web/.next/static ./web/.next/static
COPY --from=builder2 --chown=expressjs:expressjs /app/web/public ./web/public

COPY --from=builder2 --chown=expressjs:expressjs /app/packages/shared/prisma ./packages/shared/prisma
COPY --from=builder2 --chown=expressjs:expressjs /app/packages/shared/clickhouse ./packages/shared/clickhouse

COPY --chown=expressjs:expressjs ./web/entrypoint.sh ./web/entrypoint.sh
COPY --chown=expressjs:expressjs ./packages/shared/scripts/cleanup.sql ./packages/shared/scripts/cleanup.sql
RUN chmod +x ./web/entrypoint.sh


EXPOSE 3030
EXPOSE 3000
ENV WORKER_PORT 3030
ENV WEB_PORT 3000

USER root
# Docker ENTRYPOINT (dumb-init) is covered by semantic versioning, not the entrypoint.sh itself
# Reasoning: ENTRYPOINT is overridden by some self-hosted deployments, thus changing this is breaking
ENTRYPOINT ["dumb-init", "--", "/app/entrypoint.sh"]

# startup command
