FROM node:22-alpine AS dashboard
WORKDIR /app
COPY dashboard/package.json dashboard/package-lock.json* ./
RUN npm ci
COPY dashboard/ .
RUN npm run build

FROM nginx:alpine
RUN apk add --no-cache jq bash bash-completion
COPY --from=dashboard /app/dist /usr/share/nginx/html
COPY gateway/nginx.conf /etc/nginx/conf.d/default.conf
COPY gateway/entrypoint.sh /entrypoint.sh
COPY gateway/rpc-keys.sh /usr/local/bin/rpc-keys
RUN chmod +x /entrypoint.sh /usr/local/bin/rpc-keys
RUN echo '_rpc_keys() { COMPREPLY=($(compgen -W "add revoke rotate list stats" -- "${COMP_WORDS[1]}")); }; complete -F _rpc_keys rpc-keys' > /etc/profile.d/rpc-keys-completion.sh
ENTRYPOINT ["/entrypoint.sh"]
