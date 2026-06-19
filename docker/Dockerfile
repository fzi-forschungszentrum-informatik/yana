FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Execute all installations, downloads, and cleanups in a single layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gosu \
        sudo \
        make \
        build-essential \
        liblz4-dev \
        zlib1g-dev \
        python3 python3-dev python3-venv \
        jq && \
    # 1. Dynamically fetch the latest OSS CAD Suite Linux x64 release URL
    DOWNLOAD_URL=$(curl -sS https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest | jq -r '.assets[] | select(.name | test("linux-x64.*\\.tgz$")) | .browser_download_url') && \
    # 2. Stream the tarball directly into extraction to avoid writing it to disk
    curl -sSL "$DOWNLOAD_URL" | tar -xz -C /opt && \
    # 3. Strip out temporary fetching tools and completely clear the apt cache
    apt-get purge -y curl jq && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Prepend the OSS CAD Suite binary directory to the PATH
ENV PATH="/opt/oss-cad-suite/bin:${PATH}"

# Create a global venv with YANA's dependencies (CPU-only PyTorch)
COPY software_framework/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --upgrade pip && \
    /opt/venv/bin/pip install \
        --extra-index-url https://download.pytorch.org/whl/cpu \
        "torch<2.11.0" torchvision && \
    /opt/venv/bin/pip install -r /tmp/requirements.txt && \
    chmod -R a+rX /opt/venv

# Activate the venv for every interactive shell
RUN echo 'source /opt/venv/bin/activate' >> /etc/bash.bashrc

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /workspace
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

# When attaching a shell as root (e.g. docker exec), automatically drop to the host user
RUN printf '%s\n' \
    'case "$-" in' \
    '  *i*) ;;' \
    '  *) return ;;' \
    'esac' \
    '' \
    'if [ "$(id -u)" = "0" ] && [ -n "${HOST_UID}" ] && [ -n "${HOST_GID}" ]; then' \
    '    exec gosu "${HOST_UID}:${HOST_GID}" bash' \
    'fi' \
    >> /etc/bash.bashrc
