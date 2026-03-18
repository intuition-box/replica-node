FROM node:22-alpine AS dashboard
WORKDIR /app
COPY dashboard/package.json dashboard/package-lock.json* ./
RUN npm ci
COPY dashboard/ .
RUN npm run build

FROM nginx:alpine
RUN apk add --no-cache jq
COPY --from=dashboard /app/dist /usr/share/nginx/html
COPY gateway/nginx.conf /etc/nginx/conf.d/default.conf
COPY gateway/entrypoint.sh /entrypoint.sh
COPY gateway/rpc-keys.sh /usr/local/bin/rpc-keys
RUN chmod +x /entrypoint.sh /usr/local/bin/rpc-keys
ENTRYPOINT ["/entrypoint.sh"]
