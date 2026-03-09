FROM voidlinux/voidlinux:latest

# Synchronise and upgrade the package index, then install all tools required
# to orchestrate the encrypted disk setup from within the container.
RUN xbps-install -Su xbps && \
    xbps-install -y \
        cryptsetup \
        lvm2 \
        parted \
        dosfstools \
        e2fsprogs \
        util-linux \
        python3 \
        python3-PyYAML \
        xtools \
        xbps && \
    rm -rf /var/cache/xbps/*

WORKDIR /setup

COPY entrypoint.sh .
COPY void-installation-script.sh .

RUN chmod +x entrypoint.sh void-installation-script.sh

ENTRYPOINT ["/setup/entrypoint.sh"]
