FROM ghcr.io/void-linux/void-glibc

ARG VOID_XBPS_REPOSITORY="https://repo-default.voidlinux.org/current"

# Synchronise and upgrade the package index, then install all tools required
# to orchestrate the encrypted disk setup from within the container.
RUN xbps-install -iyuS \
        --repository "${VOID_XBPS_REPOSITORY}" \
        xbps && \
    xbps-install -iy \
        --repository "${VOID_XBPS_REPOSITORY}" \
        cryptsetup \
        gnupg \
        lvm2 \
        parted \
        dosfstools \
        e2fsprogs \
        util-linux \
        xtools \
        xbps && \
    rm -rf /var/cache/xbps/*

WORKDIR /setup

ENTRYPOINT ["/setup/entrypoint.sh"]
