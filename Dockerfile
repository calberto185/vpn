FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
      kmod \
      openssh-server \
      iproute2 \
      iputils-ping \
      iptables \
      iptables-persistent \
      nftables \
      curl \
      gnupg2 \
      ca-certificates \
      wget \
      sudo \
      openvpn \
      tcpdump \
      bind9-utils \
      easy-rsa \
      net-tools \
      netcat \
      vim \
      unzip \
      zip \
      dnsutils \
      openssl \
      dos2unix \
      gawk \
      uuid-runtime && \
    mkdir -p /var/run/sshd && \
    echo "root:root" | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config && \
    mkdir -p /etc/openvpn /data /var/log/openvpn /etc/openvpn/suspendidos /data/ovpn /scripts && \
    echo 'management 0.0.0.0 7505' >> /etc/openvpn/server.conf

# Copiar scripts y dar permisos
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh && dos2unix /scripts/*.sh && ln -s /scripts/ovpn_* /usr/local/bin/

# Copiar scripts base del sistema
COPY init-config.sh /usr/local/bin/init-config.sh
COPY init-openvpn.sh /usr/local/bin/init-openvpn.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY tls-verify.sh /usr/local/bin/tls-verify.sh
RUN chmod +x /usr/local/bin/init-config.sh /usr/local/bin/init-openvpn.sh /usr/local/bin/entrypoint.sh /usr/local/bin/tls-verify.sh

EXPOSE 22 1194/udp 514/udp 1195/udp 7505

CMD ["/usr/local/bin/entrypoint.sh"]

ENV DEBIAN_FRONTEND=
