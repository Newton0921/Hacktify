FROM docker.io/library/alpine:3.20

LABEL maintainer="range-ops@prabalurja.lab" \
      description="VPN Gateway — Stage 1 target" \
      stage="1" zone="public"

RUN apk add --no-cache \
        openvpn easy-rsa openssh-server openssh-sftp-server \
        openssl bash shadow coreutils iptables tini inotify-tools python3 \
    && mkdir -p /etc/openvpn/server /etc/openvpn/client \
                /run/ctf /var/log/ctf /var/run/sshd \
    && ssh-keygen -A

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1194/udp
EXPOSE 22/tcp

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/entrypoint.sh"]
