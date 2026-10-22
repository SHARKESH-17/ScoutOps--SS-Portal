# ScoutOps - production image
FROM node:22-alpine

LABEL org.opencontainers.image.title="scoutops" \
      org.opencontainers.image.description="ScoutOps - Find. Track. Resolve." \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# Copy manifests first so the dependency layer is cached until they change.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Only the runtime files are copied (no tests, scripts, or local node_modules).
COPY --chown=node:node src ./src
COPY --chown=node:node public ./public

# Run as the unprivileged "node" user shipped with the official image.
USER node

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/server.js"]
