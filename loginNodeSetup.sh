#!/bin/bash
set -euo pipefail
CONTROLLER_HOST="loginNode"
CONTROLLER_IP="10.0.0.10"
CLUSTER_NET="10.0.0.0/24"

NODE01_IP="10.0.0.11"
NODE02_IP="10.0.0.12"
NODE01_CPUs=""
NODE02_CPUS=""
NODE01_MEMORY=""
NODE02_MEMORY=""
CLUSTER_USER="clusteruser"
CLUSTER_UID="1001"
CLUSTER_GID="1001"

SLURM_USER="slurm"
SLURM_UID="992"
SLURM_GID="992"

SLURM_VERSION="25.05.8"
SLURM_DOWNLOAD_URL="https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2"

SRUN_PORT_START="60001"
SRUN_PORT_END="61000"

NFS_EXPORT="/mnt/data/users"
USERS_MOUNT="/users"
NFS_NETWORK="${CLUSTER_NET}"

CLUSTER_INTERFACE=""
EXTERNAL_INTERFACE=""

DNSMASQ_CONF="/etc/dnsmasq.d/cluster.conf"

SLURM_RPM_DIR="/users/${CLUSTER_USER}/rpmbuild/RPMS/x86_64"
SLURM_CLUSTER_DIR="/users/${CLUSTER_USER}/cluster"

SLURM_SOURCE_DIR="/tmp/slurm-build"
SLURM_SOURCE_TARBALL="${SLURM_SOURCE_DIR}/slurm-${SLURM_VERSION}.tar.bz2"
read -p "What is the internal IP of this VM? " internalIP
CONTROLLER_IP="$internalIP"
read -p "What is the internal IP of node01? " node01IP
NODE01_IP="$node01IP"
read -p "What is the internal IP of node02? " node02IP
NODE02_IP="$node02IP"
read -p "How many cpu cores is node01 expected to have? " node01cpus
NODE01_CPUS="$node01cpus"
read -p "How many cpu cores is node02 expected to have? " node02cpus
NODE02_CPUS="$node02cpus"
read -p "How much memory (in mb) is node01 expected to have? " node01memory
NODE01_MEMORY="$node01memory"
read -p "How much memory (in mb) is node02 expected to have? " node02memory
NODE02_MEMORY="$node02memory"

if [ "${EUID}" -ne 0 ]; then
    echo
    echo "ERROR: This script must be run as root."
    echo
    exit 1
fi
echo
echo "Detecting network interfaces..."

CLUSTER_INTERFACE="$(
    ip -o -4 addr show |
        awk -v ip="${CONTROLLER_IP}" '$4 == ip "/24" {print $2; exit}'
)"

if [ -z "${CLUSTER_INTERFACE}" ]; then
    echo
    echo "ERROR: Could not determine the cluster network interface."
    echo "Expected ${CONTROLLER_IP}/24 to be configured on an interface."
    echo
    ip -br -4 addr
    exit 1
fi

EXTERNAL_INTERFACE="$(
    ip route show default 2>/dev/null |
        awk 'NR==1 {print $5}'
)"

if [ -z "${EXTERNAL_INTERFACE}" ]; then
    echo
    echo "ERROR: Could not determine the external network interface."
    echo
    ip route
    exit 1
fi

echo "Cluster interface:  ${CLUSTER_INTERFACE}"
echo "External interface: ${EXTERNAL_INTERFACE}"

if [ "${CLUSTER_INTERFACE}" = "${EXTERNAL_INTERFACE}" ]; then
    echo
    echo "WARNING: Cluster and external interfaces are the same:"
    echo "         ${CLUSTER_INTERFACE}"
    echo
    echo "A two-interface gateway is recommended."
    echo
fi

echo
echo "Installing required packages..."

dnf install -y \
    curl \
    wget \
    tar \
    bzip2 \
    gzip \
    gcc \
    gcc-c++ \
    make \
    autoconf \
    automake \
    libtool \
    pkgconf-pkg-config \
    rpm-build \
    rpmdevtools \
    dnf-plugins-core \
    git \
    patch \
    diffutils \
    which \
    hostname \
    procps-ng \
    iproute \
    iputils \
    net-tools \
    openssh-server \
    firewalld \
    dnsmasq \
    nfs-utils \
    munge \
    munge-libs \
    munge-devel \
    mariadb-devel \
    pam-devel \
    readline-devel \
    openssl-devel \
    numactl-devel \
    hwloc-devel \
    json-c-devel \
    libyaml-devel \
    libcurl-devel \
    kernel-headers \
    dbus-devel \
    sudo
echo
echo "Configuring hostname..."

hostnamectl set-hostname "${CONTROLLER_HOST}"
echo
echo "Enabling IPv4 forwarding..."

cat > /etc/sysctl.d/99-cluster.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl --system
echo
echo "Configuring firewalld..."

systemctl enable --now firewalld

firewall-cmd --permanent \
    --zone=internal \
    --add-interface="${CLUSTER_INTERFACE}"

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

firewall-cmd --permanent \
    --zone=internal \
    --add-service=dns

firewall-cmd --permanent \
    --zone=external \
    --add-interface="${EXTERNAL_INTERFACE}"

firewall-cmd --permanent \
    --zone=external \
    --add-service=ssh

firewall-cmd --permanent \
    --zone=external \
    --add-masquerade

if ! firewall-cmd --permanent --get-policies | grep -qw internal-to-external; then
    firewall-cmd --permanent --new-policy internal-to-external
fi

firewall-cmd --permanent \
    --policy=internal-to-external \
    --add-ingress-zone=internal

firewall-cmd --permanent \
    --policy=internal-to-external \
    --add-egress-zone=external

firewall-cmd --permanent \
    --policy=internal-to-external \
    --set-target=ACCEPT


firewall-cmd --reload
echo
echo "Configuring dnsmasq..."

mkdir -p /etc/dnsmasq.d

cat > "${DNSMASQ_CONF}" <<EOF
interface=${CLUSTER_INTERFACE}
bind-interfaces
domain-needed
bogus-priv
server=8.8.8.8
server=1.1.1.1
address=/loginNode/${CONTROLLER_IP}
address=/node01/${NODE01_IP}
address=/node02/${NODE02_IP}
listen-address=${CONTROLLER_IP}
except-interface=lo
EOF

systemctl enable --now dnsmasq
systemctl restart dnsmasq

echo
echo "Checking DNS listener..."

if ! ss -lunpt | grep -q ":53 "; then
    echo
    echo "ERROR: dnsmasq does not appear to be listening on port 53."
    echo
    systemctl --no-pager --full status dnsmasq
    exit 1
fi
echo
echo "Configuring loginNode to use local dnsmasq for DNS..."

CLUSTER_CONNECTION="$(
    nmcli -g GENERAL.CONNECTION device show "${CLUSTER_INTERFACE}" |
        head -n1
)"

if [ -z "${CLUSTER_CONNECTION}" ] || [ "${CLUSTER_CONNECTION}" = "--" ]; then
    echo
    echo "ERROR: Could not determine NetworkManager connection for:"
    echo "  ${CLUSTER_INTERFACE}"
    exit 1
fi

EXTERNAL_CONNECTION="$(
    nmcli -g GENERAL.CONNECTION device show "${EXTERNAL_INTERFACE}" |
        head -n1
)"

nmcli connection modify "${CLUSTER_CONNECTION}" \
    ipv4.dns "${CONTROLLER_IP}" \
    ipv4.ignore-auto-dns yes

if [ -n "${EXTERNAL_CONNECTION}" ] && [ "${EXTERNAL_CONNECTION}" != "--" ]; then
    nmcli connection modify "${EXTERNAL_CONNECTION}" \
        ipv4.ignore-auto-dns yes
fi

nmcli connection up "${CLUSTER_CONNECTION}"

if [ -n "${EXTERNAL_CONNECTION}" ] && [ "${EXTERNAL_CONNECTION}" != "--" ]; then
    nmcli connection up "${EXTERNAL_CONNECTION}"
fi

echo
echo "Verifying loginNode local DNS resolution..."

if ! getent hosts node01 >/dev/null 2>&1; then
    echo
    echo "ERROR: loginNode cannot resolve node01 via local dnsmasq."
    echo
    cat /etc/resolv.conf
    exit 1
fi

echo "loginNode DNS is using local dnsmasq."
echo "Configuring NFS server..."

mkdir -p "${NFS_EXPORT}"
mkdir -p "${USERS_MOUNT}"

chmod 755 "${NFS_EXPORT}"

if ! mountpoint -q "${USERS_MOUNT}"; then
    if [ -d "${USERS_MOUNT}" ]; then
        echo
        echo "Migrating existing /users contents into ${NFS_EXPORT}..."

        rsync -aHAX \
            "${USERS_MOUNT}/" \
            "${NFS_EXPORT}/"
    fi
fi

NFS_EXPORT_ENTRY="${NFS_EXPORT} ${NFS_NETWORK}(rw,sync,no_subtree_check,no_root_squash)"

if ! grep -qF "${NFS_EXPORT_ENTRY}" /etc/exports; then
    echo "${NFS_EXPORT_ENTRY}" >> /etc/exports
fi

exportfs -rav
systemctl enable --now nfs-server
echo
echo "Configuring /users bind mount..."

BIND_FSTAB_ENTRY="${NFS_EXPORT} ${USERS_MOUNT} none bind 0 0"

if ! grep -qF "${BIND_FSTAB_ENTRY}" /etc/fstab; then
    echo "${BIND_FSTAB_ENTRY}" >> /etc/fstab
fi

systemctl daemon-reload

if ! mountpoint -q "${USERS_MOUNT}"; then
    mount "${USERS_MOUNT}"
fi

echo
echo "Verifying /users bind mount..."

findmnt "${USERS_MOUNT}"

if ! mountpoint -q "${USERS_MOUNT}"; then
    echo
    echo "ERROR: ${USERS_MOUNT} is not mounted."
    exit 1
fi
echo
echo "Configuring cluster user..."

if ! getent group "${CLUSTER_USER}" >/dev/null 2>&1; then
    groupadd \
        --gid "${CLUSTER_GID}" \
        "${CLUSTER_USER}"
fi

if ! id "${CLUSTER_USER}" >/dev/null 2>&1; then
    useradd \
        --uid "${CLUSTER_UID}" \
        --gid "${CLUSTER_GID}" \
        --home-dir "/users/${CLUSTER_USER}" \
        --create-home \
        --shell /bin/bash \
        "${CLUSTER_USER}"
fi

mkdir -p "/users/${CLUSTER_USER}"

chown \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "/users/${CLUSTER_USER}"

chmod 755 "/users/${CLUSTER_USER}"
echo
echo "Configuring passwordless sudo..."

cat > "/etc/sudoers.d/${CLUSTER_USER}" <<EOF
${CLUSTER_USER} ALL=(ALL) NOPASSWD: ALL
EOF

chmod 440 "/etc/sudoers.d/${CLUSTER_USER}"

visudo -cf "/etc/sudoers.d/${CLUSTER_USER}"
if command -v getenforce >/dev/null 2>&1 &&
   [ "$(getenforce)" != "Disabled" ]; then

    echo
    echo "Configuring SELinux for NFS home directories..."

    setsebool -P use_nfs_home_dirs on
fi
echo
echo "Configuring SSH..."

SSH_HOME="/users/${CLUSTER_USER}"
SSH_DIR="${SSH_HOME}/.ssh"
SSH_KEY="${SSH_DIR}/id_ed25519"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
SSH_CONFIG="${SSH_DIR}/config"

mkdir -p "${SSH_DIR}"

chown \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "${SSH_DIR}"

chmod 700 "${SSH_DIR}"

systemctl enable --now sshd
echo
echo "Checking cluster SSH key..."

if [ ! -f "${SSH_KEY}" ]; then
    echo "Generating cluster SSH key..."

    su -s /bin/bash - "${CLUSTER_USER}" -c \
        "ssh-keygen -t ed25519 -N '' -f '${SSH_KEY}'"
fi

if [ ! -f "${SSH_KEY}.pub" ]; then
    echo
    echo "ERROR: SSH public key was not created."
    exit 1
fi
echo
echo "Configuring SSH authorized_keys..."

touch "${AUTHORIZED_KEYS}"

if ! grep -qxF "$(cat "${SSH_KEY}.pub")" "${AUTHORIZED_KEYS}"; then
    cat "${SSH_KEY}.pub" >> "${AUTHORIZED_KEYS}"
fi

sort -u "${AUTHORIZED_KEYS}" -o "${AUTHORIZED_KEYS}"

chown \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "${AUTHORIZED_KEYS}"

chmod 600 "${AUTHORIZED_KEYS}"

cat > "${SSH_CONFIG}" <<EOF
Host *
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

chown \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "${SSH_CONFIG}"

chmod 600 "${SSH_CONFIG}"
if command -v semanage >/dev/null 2>&1 &&
   [ "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]; then

    echo
    echo "Configuring SELinux labels for clusteruser home..."

    semanage fcontext -a -t user_home_dir_t \
        "/users/${CLUSTER_USER}" 2>/dev/null || true

    semanage fcontext -a -t user_home_t \
        "/users/${CLUSTER_USER}(/.*)?" 2>/dev/null || true

    restorecon -RFv "/users/${CLUSTER_USER}" || true
fi
echo
echo "Configuring MUNGE..."

mkdir -p /etc/munge

if [ ! -s /etc/munge/munge.key ]; then
    echo "Generating MUNGE key..."

    dd \
        if=/dev/urandom \
        of=/etc/munge/munge.key \
        bs=1024 \
        count=1 \
        status=none
fi

chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key

systemctl enable munge
systemctl restart munge

echo
echo "Testing MUNGE..."

munge -n | unmunge >/dev/null

echo "MUNGE is working."
echo
echo "Configuring Slurm service account..."

if ! getent group "${SLURM_USER}" >/dev/null 2>&1; then
    groupadd \
        --system \
        --gid "${SLURM_GID}" \
        "${SLURM_USER}"
else
    CURRENT_GID="$(getent group "${SLURM_USER}" | cut -d: -f3)"

    if [ "${CURRENT_GID}" != "${SLURM_GID}" ]; then
        echo
        echo "ERROR: Existing slurm group has GID ${CURRENT_GID}; expected ${SLURM_GID}."
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
        echo "ERROR: Existing slurm account does not match UID/GID."
        id "${SLURM_USER}"
        exit 1
    fi
fi

echo
echo "Slurm service account:"
id "${SLURM_USER}"
echo
echo "Creating Slurm directories..."

mkdir -p \
    /etc/slurm \
    /var/lib/slurm \
    /var/lib/slurm/slurmctld \
    /var/lib/slurm/slurmd \
    /run/slurm

chown -R \
    "${SLURM_USER}:${SLURM_USER}" \
    /var/lib/slurm \
    /run/slurm

chmod 755 \
    /var/lib/slurm \
    /var/lib/slurm/slurmctld \
    /var/lib/slurm/slurmd \
    /run/slurm
echo
echo "Preparing Slurm source build..."

mkdir -p "${SLURM_SOURCE_DIR}"

chown \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "${SLURM_SOURCE_DIR}"

if [ ! -f "${SLURM_SOURCE_TARBALL}" ]; then
    echo
    echo "Downloading Slurm ${SLURM_VERSION}..."

    curl \
        --fail \
        --location \
        --retry 5 \
        --retry-delay 2 \
        "${SLURM_DOWNLOAD_URL}" \
        --output "${SLURM_SOURCE_TARBALL}"
fi

chown \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "${SLURM_SOURCE_TARBALL}"

echo
echo "Slurm source downloaded:"
ls -lh "${SLURM_SOURCE_TARBALL}"
echo
echo "Preparing RPM build environment..."

RPMBUILD_ROOT="/users/${CLUSTER_USER}/rpmbuild"

mkdir -p \
    "${RPMBUILD_ROOT}/BUILD" \
    "${RPMBUILD_ROOT}/BUILDROOT" \
    "${RPMBUILD_ROOT}/RPMS" \
    "${RPMBUILD_ROOT}/RPMS/x86_64" \
    "${RPMBUILD_ROOT}/SOURCES" \
    "${RPMBUILD_ROOT}/SPECS" \
    "${RPMBUILD_ROOT}/SRPMS"

chown -R \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "${RPMBUILD_ROOT}"

chmod 755 \
    "${RPMBUILD_ROOT}"

chmod 755 \
    "${RPMBUILD_ROOT}/BUILD" \
    "${RPMBUILD_ROOT}/BUILDROOT" \
    "${RPMBUILD_ROOT}/RPMS" \
    "${RPMBUILD_ROOT}/RPMS/x86_64" \
    "${RPMBUILD_ROOT}/SOURCES" \
    "${RPMBUILD_ROOT}/SPECS" \
    "${RPMBUILD_ROOT}/SRPMS"

echo
echo "RPM build directory permissions:"

ls -ld \
    "${RPMBUILD_ROOT}" \
    "${RPMBUILD_ROOT}/RPMS" \
    "${RPMBUILD_ROOT}/RPMS/x86_64"

echo
echo "RPM build directory ownership:"

stat -c '%U:%G %a %n' \
    "${RPMBUILD_ROOT}" \
    "${RPMBUILD_ROOT}/RPMS" \
    "${RPMBUILD_ROOT}/RPMS/x86_64"
RPM_TEST_FILE="${RPMBUILD_ROOT}/RPMS/x86_64/.write-test"

su -s /bin/bash - "${CLUSTER_USER}" -c \
    "touch '${RPM_TEST_FILE}' && rm -f '${RPM_TEST_FILE}'"

echo
echo "RPM output directory is writable."
echo
echo "Resolving Slurm build dependencies..."

BUILD_SOURCE_DIR="${SLURM_SOURCE_DIR}/slurm-${SLURM_VERSION}"

rm -rf "${BUILD_SOURCE_DIR}"

tar \
    -xjf "${SLURM_SOURCE_TARBALL}" \
    -C "${SLURM_SOURCE_DIR}"

SLURM_SPEC_FILE="${BUILD_SOURCE_DIR}/slurm.spec"

if [ ! -f "${SLURM_SPEC_FILE}" ]; then
    SLURM_SPEC_FILE="$(
        find "${SLURM_SOURCE_DIR}" \
            -maxdepth 3 \
            -type f \
            -name "slurm.spec" \
            -print -quit
    )"
fi

if [ -z "${SLURM_SPEC_FILE}" ] ||
   [ ! -f "${SLURM_SPEC_FILE}" ]; then

    echo
    echo "ERROR: Could not find slurm.spec."
    exit 1
fi

echo
echo "Slurm spec file:"
echo "  ${SLURM_SPEC_FILE}"

dnf builddep -y "${SLURM_SPEC_FILE}"
echo
echo "Building Slurm RPMs..."

mkdir -p "${SLURM_RPM_DIR}"

rm -f \
    "${SLURM_RPM_DIR}"/slurm-*.rpm

chown -R \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "${SLURM_SOURCE_DIR}"

su -s /bin/bash - "${CLUSTER_USER}" -c \
    "rpmbuild --with cgroupv2 -ta '${SLURM_SOURCE_TARBALL}'"
echo
echo "Checking generated Slurm RPMs..."

if [ ! -d "${SLURM_RPM_DIR}" ]; then
    echo
    echo "ERROR: Slurm RPM directory was not created:"
    echo "       ${SLURM_RPM_DIR}"
    exit 1
fi

if ! find "${SLURM_RPM_DIR}" \
    -maxdepth 1 \
    -type f \
    -name "slurm-[0-9]*.rpm" \
    -print -quit |
    grep -q .; then

    echo
    echo "ERROR: No Slurm RPMs were generated."
    exit 1
fi

ls -lh "${SLURM_RPM_DIR}"/slurm-*.rpm
echo
echo "Locating Slurm controller packages..."

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

SLURMCTLD_RPM="$(
    find "${SLURM_RPM_DIR}" \
        -maxdepth 1 \
        -type f \
        -name "slurm-slurmctld-${SLURM_VERSION}-*.rpm" \
        -print -quit
)"

if [ -z "${SLURM_RPM}" ] ||
   [ -z "${SLURM_PERLAPI_RPM}" ] ||
   [ -z "${SLURMCTLD_RPM}" ]; then

    echo
    echo "ERROR: Required Slurm controller RPMs were not found."
    exit 1
fi

echo "Slurm RPM:            ${SLURM_RPM}"
echo "Slurm Perl API RPM:   ${SLURM_PERLAPI_RPM}"
echo "Slurm controller RPM: ${SLURMCTLD_RPM}"
echo
echo "Installing Slurm controller packages..."

dnf install -y \
    "${SLURM_RPM}" \
    "${SLURM_PERLAPI_RPM}" \
    "${SLURMCTLD_RPM}"

mkdir -p \
    /var/lib/slurm \
    /var/lib/slurm/slurmctld \
    /var/lib/slurm/slurmd \
    /run/slurm

chown -R \
    "${SLURM_USER}:${SLURM_USER}" \
    /var/lib/slurm \
    /run/slurm

chmod 755 \
    /var/lib/slurm \
    /var/lib/slurm/slurmctld \
    /var/lib/slurm/slurmd \
    /run/slurm
echo
echo "Creating cluster-wide Slurm configuration..."

cat > /etc/slurm/slurm.conf <<EOF
ClusterName=cluster
SlurmctldHost=${CONTROLLER_HOST}
SlurmUser=${SLURM_USER}
SlurmdUser=root

AuthType=auth/munge
CredType=cred/munge
CryptoType=crypto/munge

SlurmctldPort=6817
SlurmdPort=6818
SrunPortRange=${SRUN_PORT_START}-${SRUN_PORT_END}

StateSaveLocation=/var/lib/slurm/slurmctld
SlurmdSpoolDir=/var/lib/slurm/slurmd

SwitchType=switch/none
MpiDefault=none
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none

SelectType=select/cons_tres
SelectTypeParameters=CR_Core

NodeName=node01 \
NodeAddr=${NODE01_IP} \
NodeHostName=node01 \
CPUs=${NODE01_CPUS} \
Boards=1 \
SocketsPerBoard=4 \
CoresPerSocket=1 \
ThreadsPerCore=1 \
RealMemory=${NODE01_MEMORY} \
State=UNKNOWN

NodeName=node02 \
NodeAddr=${NODE02_IP} \
NodeHostName=node02 \
CPUs=${NODE02_CPUS} \
Boards=1 \
SocketsPerBoard=4 \
CoresPerSocket=1 \
ThreadsPerCore=1 \
RealMemory=${NODE02_MEMORY} \
State=UNKNOWN

PartitionName=compute \
Nodes=node01,node02 \
Default=YES \
MaxTime=INFINITE \
State=UP
EOF

chmod 644 /etc/slurm/slurm.conf
chown root:root /etc/slurm/slurm.conf
rm -f /etc/slurm/cgroup.conf
echo
echo "Publishing cluster configuration..."

mkdir -p "${SLURM_CLUSTER_DIR}"

cp \
    /etc/slurm/slurm.conf \
    "${SLURM_CLUSTER_DIR}/slurm.conf"

chown \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "${SLURM_CLUSTER_DIR}/slurm.conf"

chmod 644 \
    "${SLURM_CLUSTER_DIR}/slurm.conf"

echo
echo "Creating Slurm RPM manifest..."

find "${SLURM_RPM_DIR}" \
    -maxdepth 1 \
    -type f \
    -name "slurm-*.rpm" \
    -printf "%p\n" |
    sort > "${SLURM_CLUSTER_DIR}/slurm-rpms.txt"

chown \
    "${CLUSTER_UID}:${CLUSTER_GID}" \
    "${SLURM_CLUSTER_DIR}/slurm-rpms.txt"

chmod 644 \
    "${SLURM_CLUSTER_DIR}/slurm-rpms.txt"
if [ -e "${SLURM_CLUSTER_DIR}/munge.key" ]; then
    echo
    echo "Removing insecurely published MUNGE key..."
    rm -f "${SLURM_CLUSTER_DIR}/munge.key"
fi

echo
echo "Enabling Slurm controller..."

systemctl daemon-reload
systemctl enable slurmctld
systemctl restart slurmctld
echo
echo "Waiting for slurmctld..."

for i in {1..30}; do
    if systemctl is-active --quiet slurmctld; then
        break
    fi

    if [ "${i}" -eq 30 ]; then
        echo
        echo "ERROR: slurmctld failed to start."
        echo
        journalctl -u slurmctld --no-pager -n 100
        exit 1
    fi

    sleep 2
done
echo
echo "Testing Slurm controller..."

scontrol ping
echo
echo "Testing local DNS forwarding..."

if command -v dig >/dev/null 2>&1; then

    echo
    echo "loginNode:"
    dig +short @"${CONTROLLER_IP}" loginNode

    echo
    echo "node01:"
    dig +short @"${CONTROLLER_IP}" node01

    echo
    echo "node02:"
    dig +short @"${CONTROLLER_IP}" node02

    echo
    echo "example.com:"
    dig +short @"${CONTROLLER_IP}" example.com

else
    echo "dig is not installed; skipping DNS query test."
fi
echo
echo "Cluster configuration:"
cat /etc/slurm/slurm.conf

echo
echo "MUNGE:"
systemctl --no-pager --full status munge

echo
echo "SLURMCTLD:"
systemctl --no-pager --full status slurmctld

echo
echo "Network interfaces:"
ip -br -4 addr

echo
echo "Routing:"
ip route

echo
echo "DNS listener:"
ss -lunpt | grep ':53 ' || true

echo
echo "NFS exports:"
exportfs -v

echo
echo "Internal firewall:"
firewall-cmd --zone=internal --list-all

echo
echo "External firewall:"
firewall-cmd --zone=external --list-all

echo
echo "Generated Slurm RPMs:"
ls -lh "${SLURM_RPM_DIR}"/slurm-*.rpm
echo
echo "Login node setup complete."
echo

echo "Controller:          ${CONTROLLER_HOST}"
echo "Controller IP:       ${CONTROLLER_IP}"
echo "Cluster network:     ${CLUSTER_NET}"
echo "Cluster interface:   ${CLUSTER_INTERFACE}"
echo "External interface:  ${EXTERNAL_INTERFACE}"
echo "Cluster user:        ${CLUSTER_USER}"
echo "Slurm version:       ${SLURM_VERSION}"

echo
echo "Slurm RPMs:"
echo "  ${SLURM_RPM_DIR}"

echo
echo "Slurm config:"
echo "  /etc/slurm/slurm.conf"

echo
echo "MUNGE key:"
echo "  /etc/munge/munge.key"

echo
echo "Compute-node files:"
echo "  Slurm config:    ${SLURM_CLUSTER_DIR}/slurm.conf"
echo "  Slurm RPM list:  ${SLURM_CLUSTER_DIR}/slurm-rpms.txt"

echo
echo "Compute nodes:"
echo "  node01 (${NODE01_IP})"
echo "  node02 (${NODE02_IP})"

echo
echo "DNS forwarding:"
echo "  Cluster clients -> ${CONTROLLER_IP}:53"
echo "  Upstream DNS    -> 8.8.8.8 / 1.1.1.1"

echo
echo "IPv4 forwarding: Enabled"
echo "NAT:              ${CLUSTER_NET} -> ${EXTERNAL_INTERFACE}"

echo
echo "Setup complete."
