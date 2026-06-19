#!/usr/bin/env bash
set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
HOST_USER="${HOST_USER:-user}"
HOME_DIR="/home/${HOST_USER}"

# Create user group if needed
if ! getent group "${HOST_GID}" >/dev/null; then
    groupadd --gid "${HOST_GID}" "${HOST_USER}"
fi

# Create user if needed
if ! id -u "${HOST_USER}" >/dev/null 2>&1; then
    useradd \
        --uid "${HOST_UID}" \
        --gid "${HOST_GID}" \
        --create-home \
        --home-dir "${HOME_DIR}" \
        --shell /bin/bash \
        "${HOST_USER}"
fi

# Ensure home and common cache dirs exist with correct ownership
install -d -m 0755 -o "${HOST_UID}" -g "${HOST_GID}" "${HOME_DIR}"
install -d -m 0755 -o "${HOST_UID}" -g "${HOST_GID}" "${HOME_DIR}/.cache"
install -d -m 0755 -o "${HOST_UID}" -g "${HOST_GID}" "${HOME_DIR}/.local"
install -d -m 0755 -o "${HOST_UID}" -g "${HOST_GID}" "${HOME_DIR}/.config"

# Grant passwordless sudo
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${HOST_USER}" > "/etc/sudoers.d/${HOST_USER}"
chmod 0440 "/etc/sudoers.d/${HOST_USER}"
visudo -cf "/etc/sudoers.d/${HOST_USER}"

export HOME="${HOME_DIR}"
export USER="${HOST_USER}"
export LOGNAME="${HOST_USER}"
export XDG_CACHE_HOME="${HOME_DIR}/.cache"
export XDG_DATA_HOME="${HOME_DIR}/.local/share"
export XDG_CONFIG_HOME="${HOME_DIR}/.config"

# Create torch_extensions cache dir (required by QPyTorch)
install -d -m 0755 -o "${HOST_UID}" -g "${HOST_GID}" "${HOME_DIR}/.cache/torch_extensions"

exec gosu "${HOST_UID}:${HOST_GID}" "$@"
