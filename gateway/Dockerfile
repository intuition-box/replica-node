FROM node:22-alpine AS dashboard
WORKDIR /app
COPY dashboard/package.json dashboard/package-lock.json* ./
RUN npm ci
COPY dashboard/ .
RUN npm run build

FROM node:22-alpine
RUN apk add --no-cache python3 make g++
WORKDIR /app
COPY gateway/package.json gateway/package-lock.json* ./
RUN npm ci --production && apk del python3 make g++
COPY gateway/src ./src
COPY --from=dashboard /app/dist ./public
RUN printf '#!/bin/sh\nnode /app/src/cli.js "$@"\n' > /usr/local/bin/rpc-keys && chmod +x /usr/local/bin/rpc-keys
ENV STATIC_DIR=/app/public
EXPOSE 80
CMD ["node", "src/index.js"]
