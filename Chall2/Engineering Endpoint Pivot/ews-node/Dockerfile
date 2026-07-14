FROM docker.io/library/alpine:3.20

LABEL maintainer="range-ops@prabalurja.lab" \
      description="Engineering Workstation Node — Stage 2 target" \
      stage="2" zone="station"

RUN apk add --no-cache \
        python3 \
        py3-pip \
        openssh-server \
        openssh-sftp-server \
        openssl \
        bash \
        shadow \
        coreutils \
        tini \
        qt6-qtbase \
        qt6-qtbase-x11 \
        xauth \
    && mkdir -p /run/ctf /var/run/sshd /app \
    && ssh-keygen -A

# Install build dependencies, compile c104/asyncua, build qtester104, then clean up
RUN apk add --no-cache --virtual .build-deps \
        gcc \
        g++ \
        cmake \
        make \
        python3-dev \
        musl-dev \
        linux-headers \
        git \
        qt6-qtbase-dev \
    && pip install --break-system-packages --no-cache-dir c104 asyncua \
    && git config --global http.postBuffer 524288000 \
    && git clone --depth 1 https://github.com/riclolsen/qtester104.git /tmp/qtester104 \
    && cd /tmp/qtester104 \
    && qmake6 \
    && make \
    && cp QTester104 /usr/local/bin/qtester104 \
    && cd / \
    && rm -rf /tmp/qtester104 \
    && apk del .build-deps

COPY ews_server.py /app/ews_server.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22/tcp
EXPOSE 4840/tcp

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/entrypoint.sh"]
