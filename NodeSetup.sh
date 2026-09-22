#!/bin/bash
set -e 
CONTROLLER_HOST="loginNode"
CONTROLLER_IP="10.0.0.10"
CLUSTER_NET="10.0.0.0/24"

SUPPORTED_NODES="node01 node02"

CLUSTER_USER="clusteruser"
CLUSTER_UID="1001"
CLUSTER_GID="1001"

SLURM_USER="slurm"
SLURM_UID="992"
SLURM_GID="992"

SLURM_VERSION="25.05.8"

SRUN_PORT_START="60001"
SRUN_PORT_END="61000"

NFS_SERVER="${CONTROLLER_IP}"
NFS_EXPORT="/mnt/data/users"
NFS_MOUNT="/mnt/data/users"
USERS_MOUNT="/users"

USER_HOME="${USERS_MOUNT}/${CLUSTER_USER}"
CLUSTER_SHARED_DIR="${USER_HOME}/cluster"
SLURM_RPM_DIR="${USER_HOME}/rpmbuild/RPMS/x86_64"

SUDOERS_FILE="/etc/sudoers.d/${CLUSTER_USER}"

MUNGE_TMP=""

read -p "What is the internal IP of the loginNode? " loginIP
CONTROLLER_IP="$loginIP"

cleanup() {
    if [ -n "${MUNGE_TMP}" ]; then
        rm -f "${MUNGE_TMP}"
    fi
}
trap cleanup EXIT

fail() {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo
    echo "ERROR: Run this script as root:"
    echo
    echo "  sudo $0"
    echo
    exit 1
fi

NODE_NAME="$(hostname -s)"

case " ${SUPPORTED_NODES} " in
    *" ${NODE_NAME} "*)
        ;;
    *)
        echo
        echo "ERROR: hostname '${NODE_NAME}' is not supported."
        echo
        echo "This script is intended for: ${SUPPORTED_NODES}"
        echo
        exit 1
        ;;
esac

echo "Compute node: ${NODE_NAME}"
CLUSTER_INTERFACE="$(
    ip route get "${CONTROLLER_IP}" 2>/dev/null |
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
)"

if [ -z "${CLUSTER_INTERFACE}" ]; then
    echo
    echo "ERROR: Could not determine the network interface."
    echo
    ip -br addr
    ip route
    exit 1
fi

echo "Network interface: ${CLUSTER_INTERFACE}"

if ! command -v nmcli >/dev/null 2>&1; then
    fail "nmcli is not installed."
fi

CONNECTION_NAME="$(
    nmcli -g GENERAL.CONNECTION device show "${CLUSTER_INTERFACE}" 2>/dev/null |
    head -n1
)"

if [ -z "${CONNECTION_NAME}" ] ||
   [ "${CONNECTION_NAME}" = "--" ]; then

    echo
    echo "ERROR: Could not determine NetworkManager connection for:"
    echo "  ${CLUSTER_INTERFACE}"
    echo
    nmcli connection show
    exit 1
fi

echo "NetworkManager connection: ${CONNECTION_NAME}"

echo
echo "Configuring cluster gateway and DNS..."

nmcli connection modify "${CONNECTION_NAME}" \
    ipv4.gateway "${CONTROLLER_IP}" \
    ipv4.dns "${CONTROLLER_IP}" \
    ipv4.ignore-auto-dns yes

nmcli connection up "${CONNECTION_NAME}" || true

echo
echo "Current routing table:"
ip route

echo
echo "Testing controller connectivity..."

for i in {1..60}; do
    if ping -c 1 -W 2 "${CONTROLLER_IP}" >/dev/null 2>&1; then
        break
    fi

    if [ "${i}" -eq 60 ]; then
        fail "${CONTROLLER_IP} is not reachable."
    fi

    echo "Waiting for ${CONTROLLER_IP}..."
    sleep 2
done

echo "Controller ${CONTROLLER_IP} is reachable."

echo
echo "Testing controller DNS..."

for i in {1..30}; do
    if getent hosts "${CONTROLLER_HOST}" >/dev/null 2>&1; then
        break
    fi

    if [ "${i}" -eq 30 ]; then
        echo
        echo "ERROR: ${CONTROLLER_HOST} cannot be resolved."
        echo
        cat /etc/resolv.conf
        exit 1
    fi

    sleep 2
done

echo
echo "DNS resolution:"
getent hosts "${CONTROLLER_HOST}"
echo
echo "Installing required packages..."

dnf install -y \
    sudo \
    nfs-utils \
    firewalld \
    openssh-server \
    munge \
    munge-libs \
    chrony \
    policycoreutils \
    policycoreutils-python-utils

echo
echo "Enabling time synchronization..."

systemctl enable --now chronyd

chronyc makestep >/dev/null 2>&1 || true

echo
echo "Configuring firewalld..."

systemctl enable --now firewalld

firewall-cmd --permanent \
    --zone=internal \
    --change-interface="${CLUSTER_INTERFACE}"

firewall-cmd --permanent \
    --zone=internal \
    --add-source="${CLUSTER_NET}"

firewall-cmd --permanent \
    --zone=internal \
    --add-port=6817/tcp

firewall-cmd --permanent \
    --zone=internal \
    --add-port=6818/tcp

firewall-cmd --permanent \
    --zone=internal \
    --add-port="${SRUN_PORT_START}-${SRUN_PORT_END}/tcp"

firewall-cmd --permanent \
    --zone=internal \
    --add-service=nfs

firewall-cmd --permanent \
    --zone=internal \
    --add-service=ssh

firewall-cmd --reload

echo
echo "Configuring NFS..."

mkdir -p "${NFS_MOUNT}"
mkdir -p "${USERS_MOUNT}"

NFS_FSTAB_ENTRY="${NFS_SERVER}:${NFS_EXPORT} ${NFS_MOUNT} nfs4 _netdev,defaults 0 0"
BIND_FSTAB_ENTRY="${NFS_MOUNT} ${USERS_MOUNT} none bind 0 0"

if ! grep -qF "${NFS_FSTAB_ENTRY}" /etc/fstab; then
    echo "${NFS_FSTAB_ENTRY}" >> /etc/fstab
fi

if ! grep -qF "${BIND_FSTAB_ENTRY}" /etc/fstab; then
    echo "${BIND_FSTAB_ENTRY}" >> /etc/fstab
fi

systemctl daemon-reload

echo
echo "Mounting ${NFS_MOUNT}..."

for i in {1..60}; do
    if mountpoint -q "${NFS_MOUNT}"; then
        break
    fi

    if mount "${NFS_MOUNT}" 2>/dev/null; then
        break
    fi

    if [ "${i}" -eq 60 ]; then
        fail "Could not mount ${NFS_SERVER}:${NFS_EXPORT}"
    fi

    echo "Waiting for NFS server ${NFS_SERVER}..."
    sleep 2
done

echo "NFS mount is available."

echo
echo "Mounting ${USERS_MOUNT}..."

for i in {1..30}; do
    if mountpoint -q "${USERS_MOUNT}"; then
        break
    fi

    if mount "${USERS_MOUNT}" 2>/dev/null; then
        break
    fi

    if [ "${i}" -eq 30 ]; then
        fail "Could not bind-mount ${NFS_MOUNT} to ${USERS_MOUNT}."
    fi

    echo "Waiting for ${NFS_MOUNT}..."
    sleep 2
done

echo "${USERS_MOUNT} is available."
echo
echo "Checking data published by ${CONTROLLER_HOST}..."

PROBLEMS=()

if [ ! -d "${USER_HOME}" ]; then
    PROBLEMS+=("${USER_HOME} does not exist")
else
    HOME_UID="$(stat -c %u "${USER_HOME}")"

    if [ "${HOME_UID}" != "${CLUSTER_UID}" ]; then
        PROBLEMS+=("${USER_HOME} is owned by uid ${HOME_UID}, expected ${CLUSTER_UID}")
    fi
fi

if [ ! -d "${USER_HOME}/.ssh" ]; then
    PROBLEMS+=("${USER_HOME}/.ssh does not exist")
fi

if [ ! -s "${CLUSTER_SHARED_DIR}/slurm.conf" ]; then
    PROBLEMS+=("${CLUSTER_SHARED_DIR}/slurm.conf is missing")
fi

if [ ! -d "${SLURM_RPM_DIR}" ]; then
    PROBLEMS+=("${SLURM_RPM_DIR} does not exist")
fi

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    echo
    echo "ERROR: The controller export is not ready:"
    echo

    for problem in "${PROBLEMS[@]}"; do
        echo "  - ${problem}"
    done

    echo
    echo "What this node sees in ${NFS_MOUNT}:"
    ls -la "${NFS_MOUNT}" || true
    echo
    echo "What this node sees in ${USER_HOME}:"
    ls -la "${USER_HOME}" 2>&1 || true
    echo
    echo "On ${CONTROLLER_HOST}, check that the exported directory really"
    echo "contains the cluster user's files:"
    echo
    echo "  findmnt ${USERS_MOUNT}"
    echo "  ls -la ${NFS_EXPORT}/${CLUSTER_USER}"
    echo
    echo "${USERS_MOUNT} on the controller must be a bind mount of"
    echo "${NFS_EXPORT}; otherwise files written to ${USERS_MOUNT} never"
    echo "reach the NFS export."
    echo
    exit 1
fi

echo "Controller data is available."
echo
echo "Configuring ${CLUSTER_USER}..."

if ! getent group "${CLUSTER_USER}" >/dev/null 2>&1; then

    if getent group "${CLUSTER_GID}" >/dev/null 2>&1; then
        echo
        echo "ERROR: GID ${CLUSTER_GID} is already assigned:"
        getent group "${CLUSTER_GID}"
        exit 1
    fi

    groupadd \
        --gid "${CLUSTER_GID}" \
        "${CLUSTER_USER}"

else

    CURRENT_GID="$(
        getent group "${CLUSTER_USER}" |
        cut -d: -f3
    )"

    if [ "${CURRENT_GID}" != "${CLUSTER_GID}" ]; then
        echo
        echo "ERROR: ${CLUSTER_USER} group has GID ${CURRENT_GID}."
        echo "Expected ${CLUSTER_GID}."
        exit 1
    fi
fi

if ! id "${CLUSTER_USER}" >/dev/null 2>&1; then

    if getent passwd "${CLUSTER_UID}" >/dev/null 2>&1; then
        echo
        echo "ERROR: UID ${CLUSTER_UID} is already assigned:"
        getent passwd "${CLUSTER_UID}"
        exit 1
    fi

    useradd \
        --uid "${CLUSTER_UID}" \
        --gid "${CLUSTER_GID}" \
        --home-dir "${USER_HOME}" \
        --no-create-home \
        --shell /bin/bash \
        "${CLUSTER_USER}"

else

    CURRENT_UID="$(id -u "${CLUSTER_USER}")"
    CURRENT_GID="$(id -g "${CLUSTER_USER}")"

    if [ "${CURRENT_UID}" != "${CLUSTER_UID}" ] ||
       [ "${CURRENT_GID}" != "${CLUSTER_GID}" ]; then

        echo
        echo "ERROR: ${CLUSTER_USER} account does not match."
        echo "Expected UID=${CLUSTER_UID} GID=${CLUSTER_GID}"
        id "${CLUSTER_USER}"
        exit 1
    fi
fi

echo
echo "User identity:"
id "${CLUSTER_USER}"

echo
echo "Shared home:"
ls -ld "${USER_HOME}"


echo
echo "Configuring passwordless sudo..."

cat > "${SUDOERS_FILE}" <<EOF
${CLUSTER_USER} ALL=(ALL) NOPASSWD: ALL
EOF

chmod 440 "${SUDOERS_FILE}"

visudo -cf "${SUDOERS_FILE}"

echo
echo "Testing local passwordless sudo..."

sudo -u "${CLUSTER_USER}" sudo -n whoami
if command -v getenforce >/dev/null 2>&1 &&
   [ "$(getenforce)" != "Disabled" ]; then

    echo
    echo "Enabling SELinux NFS home support..."

    setsebool -P use_nfs_home_dirs on
fi

echo
echo "Configuring SSH..."

SSH_DIR="${USER_HOME}/.ssh"

systemctl enable --now sshd

SSH_KEY=""

for key in \
    "${SSH_DIR}/id_ed25519" \
    "${SSH_DIR}/id_rsa" \
    "${SSH_DIR}/id_ecdsa"
do
    if [ -f "${key}" ]; then
        SSH_KEY="${key}"
        break
    fi
done

if [ -z "${SSH_KEY}" ]; then
    echo
    echo "ERROR: No cluster SSH private key was found."
    echo
    echo "Expected one of:"
    echo "  ${SSH_DIR}/id_ed25519"
    echo "  ${SSH_DIR}/id_rsa"
    echo "  ${SSH_DIR}/id_ecdsa"
    exit 1
fi

echo
echo "Using SSH identity:"
echo "  ${SSH_KEY}"

SSH_OPTIONS=(
    -i "${SSH_KEY}"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
)

echo
echo "Testing SSH access to ${CONTROLLER_HOST}..."

if ! sudo -u "${CLUSTER_USER}" \
    ssh \
        "${SSH_OPTIONS[@]}" \
        "${CLUSTER_USER}@${CONTROLLER_HOST}" \
        'true'
then
    echo
    echo "ERROR: SSH authentication to ${CONTROLLER_HOST} failed."
    echo
    echo "On ${CONTROLLER_HOST} check:"
    echo "  journalctl -u sshd -n 50"
    echo "  ls -laZ ${SSH_DIR}"
    echo
    echo "The controller's authorized_keys/SELinux configuration is not ready."
    exit 1
fi

echo "SSH authentication successful."

echo
echo "Checking passwordless sudo on ${CONTROLLER_HOST}..."

sudo -u "${CLUSTER_USER}" \
    ssh \
        "${SSH_OPTIONS[@]}" \
        "${CLUSTER_USER}@${CONTROLLER_HOST}" \
        'sudo -n true'

echo "Remote passwordless sudo is working."

echo
echo "Retrieving MUNGE key from ${CONTROLLER_HOST}..."

MUNGE_TMP="$(mktemp)"
chmod 600 "${MUNGE_TMP}"

sudo -u "${CLUSTER_USER}" \
    ssh \
        "${SSH_OPTIONS[@]}" \
        "${CLUSTER_USER}@${CONTROLLER_HOST}" \
        'sudo -n cat /etc/munge/munge.key' \
        > "${MUNGE_TMP}"

if [ ! -s "${MUNGE_TMP}" ]; then
    fail "Failed to retrieve MUNGE key."
fi

install \
    -o munge \
    -g munge \
    -m 400 \
    "${MUNGE_TMP}" \
    /etc/munge/munge.key

rm -f "${MUNGE_TMP}"
MUNGE_TMP=""

echo "MUNGE key installed."

systemctl enable munge
systemctl restart munge

echo
echo "Testing MUNGE locally..."

munge -n | unmunge >/dev/null

echo "MUNGE is working."

echo
echo "Testing MUNGE credential against ${CONTROLLER_HOST}..."

if ! munge -n |
    sudo -u "${CLUSTER_USER}" \
        ssh \
            "${SSH_OPTIONS[@]}" \
            "${CLUSTER_USER}@${CONTROLLER_HOST}" \
            'unmunge' >/dev/null
then
    echo
    echo "ERROR: ${CONTROLLER_HOST} could not decode a credential from this node."
    echo
    echo "Check for clock skew (chronyc tracking) and that the key matches."
    echo
    exit 1
fi

echo "MUNGE credentials are valid across nodes."
echo
echo "Checking Slurm service account..."

if ! getent group "${SLURM_USER}" >/dev/null 2>&1; then

    groupadd \
        --system \
        --gid "${SLURM_GID}" \
        "${SLURM_USER}"

else

    CURRENT_GID="$(getent group "${SLURM_USER}" | cut -d: -f3)"

    if [ "${CURRENT_GID}" != "${SLURM_GID}" ]; then
        echo
        echo "ERROR: ${SLURM_USER} group has GID ${CURRENT_GID}."
        echo "Expected ${SLURM_GID}."
        exit 1
    fi
fi

if ! id "${SLURM_USER}" >/dev/null 2>&1; then

    useradd \
        --system \
        --uid "${SLURM_UID}" \
        --gid "${SLURM_GID}" \
        --home-dir /var/lib/slurm \
        --shell /sbin/nologin \
        "${SLURM_USER}"

else

    CURRENT_UID="$(id -u "${SLURM_USER}")"
    CURRENT_GID="$(id -g "${SLURM_USER}")"

    if [ "${CURRENT_UID}" != "${SLURM_UID}" ] ||
       [ "${CURRENT_GID}" != "${SLURM_GID}" ]; then

        echo
        echo "ERROR: ${SLURM_USER} account does not match."
        echo "Expected UID=${SLURM_UID} GID=${SLURM_GID}"
        id "${SLURM_USER}"
        exit 1
    fi
fi

echo
echo "Slurm service account:"
id "${SLURM_USER}"
echo
echo "Locating Slurm ${SLURM_VERSION} RPMs in ${SLURM_RPM_DIR}..."

SLURM_RPM="$(
    find "${SLURM_RPM_DIR}" \
        -maxdepth 1 \
        -type f \
        -name "slurm-${SLURM_VERSION}-*.rpm" \
        -print -quit
)"

SLURM_PERLAPI_RPM="$(
    find "${SLURM_RPM_DIR}" \
        -maxdepth 1 \
        -type f \
        -name "slurm-perlapi-${SLURM_VERSION}-*.rpm" \
        -print -quit
)"

SLURMD_RPM="$(
    find "${SLURM_RPM_DIR}" \
        -maxdepth 1 \
        -type f \
        -name "slurm-slurmd-${SLURM_VERSION}-*.rpm" \
        -print -quit
)"

if [ -z "${SLURM_RPM}" ] ||
   [ -z "${SLURM_PERLAPI_RPM}" ] ||
   [ -z "${SLURMD_RPM}" ]; then

    echo
    echo "ERROR: Required Slurm ${SLURM_VERSION} RPMs were not found."
    echo
    echo "Available Slurm RPMs:"
    find "${SLURM_RPM_DIR}" \
        -maxdepth 1 \
        -type f \
        -name 'slurm*.rpm' \
        -printf '  %f\n' |
        sort
    exit 1
fi

echo
echo "Installing:"
echo "  ${SLURM_RPM}"
echo "  ${SLURM_PERLAPI_RPM}"
echo "  ${SLURMD_RPM}"

dnf install -y \
    "${SLURM_RPM}" \
    "${SLURM_PERLAPI_RPM}" \
    "${SLURMD_RPM}"

echo "Slurm packages installed."

mkdir -p \
    /etc/slurm \
    /var/lib/slurm \
    /var/lib/slurm/slurmd

chown slurm:slurm /var/lib/slurm
chown root:root /var/lib/slurm/slurmd

chmod 755 \
    /var/lib/slurm \
    /var/lib/slurm/slurmd

echo
echo "Installing controller Slurm configuration..."

cp \
    "${CLUSTER_SHARED_DIR}/slurm.conf" \
    /etc/slurm/slurm.conf

chmod 644 /etc/slurm/slurm.conf
chown root:root /etc/slurm/slurm.conf

USE_CGROUP=0

if [ -s "${CLUSTER_SHARED_DIR}/cgroup.conf" ]; then

    if [ ! -f /usr/lib64/slurm/cgroup_v2.so ]; then
        echo
        echo "ERROR: The controller published cgroup.conf but the installed"
        echo "Slurm build does not contain /usr/lib64/slurm/cgroup_v2.so."
        echo
        echo "Rebuild Slurm with cgroup/v2 support on the controller, or"
        echo "remove ${CLUSTER_SHARED_DIR}/cgroup.conf."
        exit 1
    fi

    cp \
        "${CLUSTER_SHARED_DIR}/cgroup.conf" \
        /etc/slurm/cgroup.conf

    chmod 644 /etc/slurm/cgroup.conf
    chown root:root /etc/slurm/cgroup.conf

    USE_CGROUP=1
    echo "Installed cgroup.conf from controller."

else

    rm -f /etc/slurm/cgroup.conf
    echo "No cgroup.conf published by controller; running without cgroups."
fi

if ! grep -qE "^NodeName=${NODE_NAME}[[:space:]]" \
    /etc/slurm/slurm.conf; then

    echo
    echo "ERROR: ${NODE_NAME} is not defined in the controller slurm.conf."
    echo
    exit 1
fi

echo
echo "Detecting node hardware..."

if ! SLURMD_CONFIG="$(slurmd -C 2>&1)"; then
    echo
    echo "ERROR: slurmd -C failed:"
    echo "${SLURMD_CONFIG}"
    exit 1
fi

echo
echo "Detected hardware:"
echo "${SLURMD_CONFIG}"

CONTROLLER_NODE_LINE="$(
    grep -E "^NodeName=${NODE_NAME}[[:space:]]" \
        /etc/slurm/slurm.conf |
    head -n1
)"

EXPECTED_CPUS="$(
    echo "${CONTROLLER_NODE_LINE}" |
    sed -n 's/.*CPUs=\([0-9]*\).*/\1/p'
)"

EXPECTED_MEMORY="$(
    echo "${CONTROLLER_NODE_LINE}" |
    sed -n 's/.*RealMemory=\([0-9]*\).*/\1/p'
)"

ACTUAL_CPUS="$(
    echo "${SLURMD_CONFIG}" |
    sed -n 's/.*CPUs=\([0-9]*\).*/\1/p' |
    head -n1
)"

ACTUAL_MEMORY="$(
    echo "${SLURMD_CONFIG}" |
    sed -n 's/.*RealMemory=\([0-9]*\).*/\1/p' |
    head -n1
)"

if [ -n "${EXPECTED_CPUS}" ] &&
   [ -n "${ACTUAL_CPUS}" ] &&
   [ "${EXPECTED_CPUS}" != "${ACTUAL_CPUS}" ]; then

    echo
    echo "WARNING: CPU count differs from controller configuration."
    echo "  Controller: ${EXPECTED_CPUS}"
    echo "  Node:       ${ACTUAL_CPUS}"
    echo
fi

if [ -n "${EXPECTED_MEMORY}" ] &&
   [ -n "${ACTUAL_MEMORY}" ] &&
   [ "${ACTUAL_MEMORY}" -lt "${EXPECTED_MEMORY}" ]; then

    echo
    echo "ERROR: Node has less memory than controller configuration."
    echo "  Controller RealMemory: ${EXPECTED_MEMORY} MB"
    echo "  Node RealMemory:       ${ACTUAL_MEMORY} MB"
    echo
    echo "Slurm would drain this node. Lower RealMemory in the controller"
    echo "slurm.conf (and re-publish it) or give the node more memory."
    echo
    exit 1
fi
echo
echo "Configuring slurmd systemd drop-in..."

mkdir -p /etc/systemd/system/slurmd.service.d

{
    echo "[Unit]"
    echo "Wants=network-online.target"
    echo "After=network-online.target remote-fs.target"
    echo "RequiresMountsFor=${USERS_MOUNT}"

    if [ "${USE_CGROUP}" -eq 1 ]; then
        echo
        echo "[Service]"
        echo "Delegate=yes"
    fi
} > /etc/systemd/system/slurmd.service.d/10-cluster.conf

systemctl daemon-reload
echo
echo "Slurm configuration:"
echo "------------------------------------------------------------"
cat /etc/slurm/slurm.conf
echo "------------------------------------------------------------"

echo
echo "Starting slurmd..."

systemctl enable slurmd

if ! systemctl restart slurmd ||
   ! { sleep 2; systemctl is-active --quiet slurmd; }; then

    echo
    echo "ERROR: slurmd failed to start."
    echo

    echo "slurmd status:"
    systemctl --no-pager --full status slurmd || true

    echo
    echo "slurmd journal:"
    journalctl -u slurmd --no-pager -n 100 || true

    exit 1
fi

echo "slurmd is running."
echo
echo "Testing controller from this node..."

if scontrol ping; then
    echo "Controller is responding."
else
    echo
    echo "WARNING: scontrol ping failed."
    echo "Check that ports 6817/6818 are open on ${CONTROLLER_HOST}"
    echo "(firewall-cmd --zone=internal --list-all) and that slurmctld is running."
fi

echo
echo "Node:"
hostname -s

echo
echo "Network:"
ip -br addr

echo
echo "Routing:"
ip route

echo
echo "NFS:"
findmnt "${NFS_MOUNT}"
findmnt "${USERS_MOUNT}"

echo
echo "SLURMD:"
systemctl --no-pager --full status slurmd || true

echo
echo "Firewall:"
firewall-cmd --zone=internal --list-all

echo
echo "Setup complete for ${NODE_NAME}."

echo
echo "You can now test from loginNode with:"
echo
echo "  scontrol show node ${NODE_NAME}"
echo "  sinfo"
echo
echo "and:"
echo
echo "  srun -N1 -w ${NODE_NAME} hostname"
echo
echo "If the node shows as DOWN/UNKNOWN, run on loginNode:"
echo
echo "  sudo scontrol update NodeName=${NODE_NAME} State=RESUME"
echo
