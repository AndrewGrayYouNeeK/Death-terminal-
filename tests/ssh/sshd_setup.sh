#!/bin/sh
# Starts a throwaway OpenSSH server for the SSH integration tests.
#
#   tests/ssh/sshd_setup.sh start <workdir>   # prints nothing on success
#   tests/ssh/sshd_setup.sh stop  <workdir>
#
# Needs openssh-server and passwordless sudo (sshd must run as root for
# password / keyboard-interactive logins). It creates a local user
# "dttest" with a fixed test-only password and listens on 127.0.0.1 only:
#   2222  publickey only (plain key, encrypted key, ssh-agent key)
#   2223  keyboard-interactive only (PAM)
#   2224  password only
set -eu
cmd=${1:?start|stop}
work=${2:?workdir}
user=dttest
pass=dt-test-pw-123
sshd=$(command -v sshd || echo /usr/sbin/sshd)

case $cmd in
stop)
    for p in "$work/sshd.pid" "$work/sshd_other.pid"; do
        if [ -f "$p" ]; then sudo -n kill "$(cat "$p")" 2>/dev/null || true; fi
    done
    # Sessions outlive the listener; they belong to the throwaway test user.
    sudo -n pkill -u dttest 2>/dev/null || true
    exit 0 ;;
start) ;;
*) echo "usage: $0 start|stop <workdir>" >&2; exit 2 ;;
esac

[ -x "$sshd" ] || { echo "sshd not found: apt install openssh-server" >&2; exit 77; }
sudo -n true 2>/dev/null || { echo "passwordless sudo is required" >&2; exit 77; }

mkdir -p "$work/keys"
chmod 755 "$work" "$work/keys"
# Host keys (a second one plays the "changed key" server).
[ -f "$work/keys/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C dt-host -f "$work/keys/host_ed25519"
[ -f "$work/keys/other_host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C dt-other -f "$work/keys/other_host_ed25519"
# Client keys: plain, encrypted, and one only the agent holds.
[ -f "$work/keys/id_plain" ] || ssh-keygen -q -t ed25519 -N '' -C plain -f "$work/keys/id_plain"
[ -f "$work/keys/id_enc" ] || ssh-keygen -q -t ed25519 -N 'dt-test-passphrase' -C enc -f "$work/keys/id_enc"
[ -f "$work/keys/id_agent" ] || ssh-keygen -q -t ed25519 -N '' -C agent -f "$work/keys/id_agent"

if ! id "$user" >/dev/null 2>&1; then
    sudo -n useradd -m -s /bin/bash "$user"
fi
echo "$user:$pass" | sudo -n chpasswd
home=$(getent passwd "$user" | cut -d: -f6)
sudo -n mkdir -p "$home/.ssh"
cat "$work/keys/id_plain.pub" "$work/keys/id_enc.pub" "$work/keys/id_agent.pub" | sudo -n tee "$home/.ssh/authorized_keys" >/dev/null
sudo -n chown -R "$user:" "$home/.ssh"
sudo -n chmod 700 "$home/.ssh"
sudo -n chmod 600 "$home/.ssh/authorized_keys"

cat > "$work/sshd_config" <<CONF
ListenAddress 127.0.0.1
Port 2222
Port 2223
Port 2224
HostKey $work/keys/host_ed25519
PidFile $work/sshd.pid
UsePAM yes
PermitRootLogin no
AllowUsers $user
PubkeyAuthentication yes
KbdInteractiveAuthentication yes
PasswordAuthentication yes
AllowTcpForwarding yes
GatewayPorts no
PermitTTY yes
AcceptEnv LANG LC_* DT_TEST_*
PrintMotd no
StrictModes no
LogLevel VERBOSE
Match LocalPort 2222
    AuthenticationMethods publickey
Match LocalPort 2223
    AuthenticationMethods keyboard-interactive
Match LocalPort 2224
    AuthenticationMethods password
CONF
# The "changed host key" server: same ports + 10, other host key.
sed -e "s#host_ed25519#other_host_ed25519#; s#sshd.pid#sshd_other.pid#; s#^Port 222#Port 223#" "$work/sshd_config" > "$work/sshd_other_config"

sudo -n mkdir -p /run/sshd
# OpenSSH >= 9.8 penalises sources with failed logins; the tests fail on purpose.
if sudo -n "$sshd" -t -f "$work/sshd_config" -o PerSourcePenalties=no 2>/dev/null; then
    for f in "$work/sshd_config" "$work/sshd_other_config"; do
        sed -i "1i PerSourcePenalties no" "$f"
    done
fi
sudo -n "$sshd" -t -f "$work/sshd_config"
sudo -n "$sshd" -f "$work/sshd_config" -E "$work/sshd.log"
sudo -n "$sshd" -f "$work/sshd_other_config" -E "$work/sshd_other.log"
sudo -n chmod 644 "$work/sshd.log" "$work/sshd_other.log" 2>/dev/null || true
# Wait for the ports.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 -c "import socket; socket.create_connection(('127.0.0.1', 2222), 1); socket.create_connection(('127.0.0.1', 2232), 1)" 2>/dev/null; then exit 0; fi
    sleep 0.2
done
echo "sshd did not start; see $work/sshd.log" >&2
exit 1
