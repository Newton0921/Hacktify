FROM alpine:latest
RUN apk add --no-cache openssh bash python3 openssl tcpdump iproute2 sudo
RUN mkdir -p /var/run/sshd
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
