# syntax=docker/dockerfile:1.7

# ---- build stage: run the unit tests inside the build, so a red test = no image ----
FROM node:22.11.0-alpine3.20 AS build
WORKDIR /app
# The app has zero runtime dependencies. If it gains some, add a lockfile and
# `RUN npm ci --omit=dev` here (before copying src) to keep the layer cacheable.
COPY package.json ./
COPY src ./src
COPY test ./test
RUN node --test

# ---- runtime stage ----
FROM node:22.11.0-alpine3.20 AS runtime

ARG VERSION=dev
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="devops-task-app" \
      org.opencontainers.image.description="Small observable web service for the DevOps assessment" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="MIT"

# Remove tooling the running service never needs (npm/yarn): smaller image, fewer CVEs,
# and no package manager for an attacker to use. Done as root before dropping privileges.
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx \
           /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*

WORKDIR /app
COPY --from=build --chown=node:node /app/package.json ./
COPY --from=build --chown=node:node /app/src ./src
COPY --chown=node:node healthcheck.js ./

ENV NODE_ENV=production \
    PORT=8080 \
    LOG_LEVEL=info \
    APP_ENV=production \
    APP_VERSION=${VERSION}

# Numeric UID so Kubernetes `runAsNonRoot` can verify it (the "node" user is 1000).
USER 1000:1000
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "healthcheck.js"]

# Exec form: node is PID 1 and receives SIGTERM directly (handled for graceful shutdown).
CMD ["node", "src/index.js"]
