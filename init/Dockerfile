FROM alpine:3.20
RUN apk add --no-cache curl jq busybox-extras
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
