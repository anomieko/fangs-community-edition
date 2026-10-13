#!/usr/bin/env bash
# Day-1 hardening for a fresh Debian 12/13 server hosting Fangs: Community Edition.
# Run as root ON THE SERVER:  bash harden.sh <admin-user> <authorized_keys-file>
# Env: LOCK_ROOT=0 skips locking the root password (do that only after testing the admin login).
#
#  - admin user with your SSH key + passwordless sudo; root login and password logins disabled
#  - firewall (nftables): deny inbound except SSH + game ports
#  - fail2ban for SSH, unattended security upgrades, root password locked
# Safe to re-run.
set -euo pipefail
admin=${1:?admin user}; keys=${2:?authorized_keys file for the admin user}
GAME_TCP="8080"; GAME_UDP="11032, 7777-7786"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo nftables fail2ban unattended-upgrades apt-listchanges rsync ca-certificates >/dev/null

# --- admin user (key-only) --------------------------------------------------------------------
id "$admin" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$admin"
passwd -l "$admin" >/dev/null                      # no password at all: key login only
install -d -m 700 -o "$admin" -g "$admin" "/home/$admin/.ssh"
install -m 600 "$keys" "/home/$admin/.ssh/authorized_keys"
chown "$admin:$admin" "/home/$admin/.ssh/authorized_keys"; chmod 600 "/home/$admin/.ssh/authorized_keys"
echo "$admin ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$admin"; chmod 440 "/etc/sudoers.d/90-$admin"
visudo -cq

# --- SSH ----------------------------------------------------------------------------------------
cat > /etc/ssh/sshd_config.d/10-fangs-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
AllowUsers $admin
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
EOF
sshd -t
[[ ${LOCK_ROOT:-1} == 1 ]] && passwd -l root >/dev/null   # root password was shared in chat: lock it

# --- firewall -----------------------------------------------------------------------------------
# Only our own table is replaced, so Docker's and fail2ban's tables are left alone.
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
table inet fangs
delete table inet fangs
table inet fangs {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif lo accept
    meta l4proto { icmp, ipv6-icmp } limit rate 20/second accept
    tcp dport 22 accept
    tcp dport { $GAME_TCP } accept
    udp dport { $GAME_UDP } accept
  }
}
EOF
systemctl enable --now nftables >/dev/null
nft -f /etc/nftables.conf

# --- fail2ban + automatic security updates ------------------------------------------------------
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
banaction = nftables-multiport
maxretry = 4
findtime = 10m
bantime = 1h
bantime.increment = true
EOF
systemctl enable --now fail2ban >/dev/null; systemctl restart fail2ban
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades >/dev/null

# --- kernel network hardening -------------------------------------------------------------------
cat > /etc/sysctl.d/90-fangs-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
sysctl -q --system

systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo "hardening done: log in as $admin with your key (root and password logins are disabled)"
