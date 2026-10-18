#!/usr/bin/env python3
"""SSH integration tests for DeathTerminal's built-in client.

Runs `deathterminal --ssh-session ...` in a pseudo-terminal against a
throwaway OpenSSH server (tests/ssh/sshd_setup.sh) and answers the
in-terminal prompts like a user would. Covers: unknown / accepted /
once / changed / revoked host keys; plain, encrypted and agent keys;
keyboard-interactive; password; remote PTY size and resize; env and the
startup command; exit status; -L / -R / -D forwarding with curl and
runtime toggles; ProxyJump; reconnect; and that secrets never show up
on screen or on disk.

    zig build test-ssh            # or: python3 tests/ssh/run.py zig-out/bin/deathterminal

Exit code 77 = skipped (no sshd / sudo).
"""
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import http.server
import socketserver

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "../../zig-out/bin/deathterminal"))
PASSWORD = "dt-test-pw-123"
PASSPHRASE = "dt-test-passphrase"
HTTP_PORT = 18080
BODY = b"hello from behind ssh\n"

failures = []
passed = 0


def check(cond, what):
    global passed
    if cond:
        passed += 1
        print(f"  ok   {what}")
    else:
        failures.append(what)
        print(f"  FAIL {what}")


class Session:
    """The client in a pty, with expect()."""

    def __init__(self, env, target, extra=(), rows=24, cols=80):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(BIN, [BIN, "--ssh-session", target, *extra], env)
        self.set_size(rows, cols, signal_child=False)
        self.out = b""
        self.status = None
        self.eof = False

    def set_size(self, rows, cols, signal_child=True):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        if signal_child:
            os.kill(self.pid, signal.SIGWINCH)

    def _read(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return False
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            data = b""
        if not data:
            self.eof = True
            return None
        self.out += data
        return True

    def expect(self, pattern, timeout=10):
        rx = re.compile(pattern.encode() if isinstance(pattern, str) else pattern)
        deadline = time.time() + timeout
        start = 0
        while True:
            m = rx.search(self.out, start)
            if m:
                self.mark = m.end()
                return m
            left = deadline - time.time()
            if left <= 0 or self.eof:
                return None
            self._read(left)

    def send(self, s):
        os.write(self.fd, s.encode() if isinstance(s, str) else s)

    def wait(self, timeout=10):
        if self.status is not None:
            return self.status
        deadline = time.time() + timeout
        while time.time() < deadline:
            pid, st = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(st)
                return self.status
            if self.eof:
                time.sleep(0.05)
                continue
            try:
                self._read(0.1)
            except OSError:
                time.sleep(0.05)
        return None

    def close(self):
        if self.status is None:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            self.wait(5)
        try:
            os.close(self.fd)
        except OSError:
            pass

    def shell_ready(self, timeout=15):
        """Wait for a remote shell: run a marker command."""
        self.send("echo READY-$((40+2))\r")
        return self.expect(r"READY-42", timeout) is not None

    def run(self, cmd, pattern, timeout=10):
        self.out_mark = len(self.out)
        self.send(cmd + "\r")
        return self.expect(pattern, timeout)


def curl(*args):
    p = subprocess.run(["curl", "-s", "--max-time", "5", *args], capture_output=True)
    return p.stdout


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *a):
        pass


def main():
    if not os.access(BIN, os.X_OK):
        print(f"missing binary {BIN}; run zig build first")
        return 1
    work = tempfile.mkdtemp(prefix="dt-ssh-")
    os.chmod(work, 0o755)
    setup = os.path.join(HERE, "sshd_setup.sh")
    r = subprocess.run(["sh", setup, "start", work])
    if r.returncode == 77:
        print("SKIP: sshd / sudo not available")
        return 77
    if r.returncode != 0:
        print("could not start sshd")
        return 1
    socketserver.TCPServer.allow_reuse_address = True  # reruns: TIME_WAIT
    httpd = None
    for _ in range(60):  # a just-finished run can hold the port briefly
        try:
            httpd = socketserver.TCPServer(("127.0.0.1", HTTP_PORT), QuietHandler)
            break
        except OSError as e:
            err = e
            time.sleep(1)
    if httpd is None:
        subprocess.run(["sh", setup, "stop", work])
        print(f"cannot listen on 127.0.0.1:{HTTP_PORT}: {err}")
        return 1
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    agent = None
    try:
        agent = run_all(work)
    finally:
        httpd.shutdown()
        if agent:
            subprocess.run(["ssh-agent", "-k"], env=agent, capture_output=True)
        subprocess.run(["sh", setup, "stop", work])
    print(f"\n{passed} passed, {len(failures)} failed")
    for f in failures:
        print(f"  - {f}")
    if not failures:
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"(kept {work} for inspection)")
    return 1 if failures else 0


def run_all(work):
    keys = os.path.join(work, "keys")
    home = os.path.join(work, "home")
    sshdir = os.path.join(home, ".ssh")
    os.makedirs(sshdir, mode=0o700, exist_ok=True)
    cfgdir = os.path.join(work, "cfg", "death-terminal")
    os.makedirs(cfgdir, exist_ok=True)
    rundir = os.path.join(work, "run")
    os.makedirs(rundir, mode=0o700, exist_ok=True)
    kh = os.path.join(sshdir, "known_hosts")
    with open(os.path.join(sshdir, "config"), "w") as f:
        f.write(f"""Host dtbox
    HostName 127.0.0.1
    User dttest
    Port 2222
    IdentityFile {keys}/id_plain
Include conf.d/*
""")
    os.makedirs(os.path.join(sshdir, "conf.d"), exist_ok=True)
    with open(os.path.join(sshdir, "conf.d", "pw.conf"), "w") as f:
        f.write("Host dtpw\n    HostName 127.0.0.1\n    Port 2224\n    User dttest\n")
    with open(os.path.join(cfgdir, "config.lua"), "w") as f:
        f.write(f"""
config.ssh.profiles = {{
  plain = {{ host = "127.0.0.1", port = 2222, user = "dttest", identity_file = "{keys}/id_plain",
            env = {{ DT_TEST_VAR = "hello-env", NOT_ACCEPTED = "x" }}, command = "echo started-$DT_TEST_VAR",
            theme = "dracula" }},
  enc = {{ host = "dttest@127.0.0.1:2222", identity_file = "{keys}/id_enc" }},
  agent = {{ host = "127.0.0.1", port = 2222, user = "dttest", identity_file = "{keys}/nope" }},
  kbd = {{ host = "127.0.0.1", port = 2223, user = "dttest", identity_file = "{keys}/nope" }},
  fwd = {{ host = "127.0.0.1", port = 2222, user = "dttest", identity_file = "{keys}/id_plain",
          forwards = {{ "L 18081:127.0.0.1:{HTTP_PORT}", "D 18082", "R 18083:127.0.0.1:{HTTP_PORT}",
                       {{ "L 18084:127.0.0.1:{HTTP_PORT}", enabled = false }} }}, keepalive_s = 1 }},
  jump = {{ host = "127.0.0.1", port = 2222, user = "dttest", identity_file = "{keys}/id_plain",
           jump = "dttest@127.0.0.1:2222" }},
  flaky = {{ host = "127.0.0.1", port = 2222, user = "dttest", identity_file = "{keys}/id_plain",
            reconnect = true, keepalive_s = 2 }},
  changed = {{ host = "127.0.0.1", port = 2232, user = "dttest", identity_file = "{keys}/id_plain" }},
}}
""")
    base_env = {
        "HOME": home, "USER": "tester", "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TERM": "xterm-256color", "XDG_CONFIG_HOME": os.path.join(work, "cfg"),
        "XDG_RUNTIME_DIR": rundir, "LANG": "C.UTF-8",
    }
    env = dict(base_env)

    def kh_text():
        try:
            return open(kh).read()
        except FileNotFoundError:
            return ""

    print("host keys")
    s = Session(env, "plain")
    check(s.expect(r"authenticity of host '\[127\.0\.0\.1\]:2222' can't be established") is not None, "unknown host key: prompt shown")
    check(s.expect(r"ED25519 key fingerprint is SHA256:[A-Za-z0-9+/]{43}") is not None, "unknown host key: SHA256 fingerprint shown")
    s.send("n\r")
    check(s.expect("Host key verification failed") is not None, "reject: refused")
    check(s.wait() == 255, "reject: exit 255")
    check(kh_text() == "", "reject: nothing saved")
    s.close()

    s = Session(env, "plain")
    s.expect(r"\[o\]nce")
    s.send("o\r")
    check(s.shell_ready(), "once: connected")
    s.send("exit\r")
    s.wait()
    check(kh_text() == "", "once: nothing saved")
    s.close()

    s = Session(env, "plain")
    s.expect(r"\[y\]es")
    s.send("y\r")
    check(s.expect(r"Permanently added '\[127\.0\.0\.1\]:2222'") is not None, "accept: saved message")
    check(s.shell_ready(), "accept: connected")
    check(s.expect(r"started-hello-env", 5) is not None, "profile env + startup command ran remotely")
    check(s.run("echo NA=[$NOT_ACCEPTED]", r"NA=\[\]") is not None, "env not in AcceptEnv is dropped by the server")
    check(s.run("echo $TERM", r"xterm-256color") is not None, "remote TERM")
    s.send("exit 7\r")
    check(s.wait() == 7, "remote exit status propagates (7)")
    s.close()
    check("[127.0.0.1]:2222 ssh-ed25519 " in kh_text(), "accept: key appended to known_hosts")

    nenv = dict(env, DT_SSH_NONCE="0123abcd")
    s = Session(nenv, "plain")
    check(s.shell_ready() and b"authenticity" not in s.out, "known host: no prompt")
    check(b"\x1b]7799;0123abcd;connect;" in s.out, "plugin hook: connect report (OSC 7799) with the nonce")
    s.send("exit\r")
    check(s.wait() == 0, "exit 0")
    check(b"\x1b]7799;0123abcd;disconnect;" in s.out, "plugin hook: disconnect report")
    s.close()

    # A server presenting a different key on a known name.
    with open(kh, "a") as f:
        pub = open(os.path.join(keys, "host_ed25519.pub")).read().split()
        f.write(f"[127.0.0.1]:2232 {pub[0]} {pub[1]}\n")
    s = Session(env, "changed")
    check(s.expect("REMOTE HOST IDENTIFICATION HAS CHANGED") is not None, "changed key: warning")
    check(s.expect(r"ssh-keygen -R '\[127\.0\.0\.1\]:2232'") is not None, "changed key: tells how to fix")
    check(s.wait() == 255, "changed key: hard block (exit 255)")
    check(b"assword" not in s.out and b"passphrase" not in s.out, "changed key: no auth attempted")
    s.close()
    # @revoked
    with open(kh, "a") as f:
        pub = open(os.path.join(keys, "other_host_ed25519.pub")).read().split()
        f.write(f"@revoked * {pub[0]} {pub[1]}\n")
    s = Session(env, "dttest@127.0.0.1:2233")
    check(s.expect("REVOKED HOST KEY") is not None and s.wait() == 255, "revoked key: blocked")
    s.close()

    print("auth")
    s = Session(env, "enc")
    check(s.expect(r"Enter passphrase for key '.*id_enc': ") is not None, "encrypted key: passphrase prompt")
    s.send("wrong-passphrase\r")
    check(s.expect("Bad passphrase, try again") is not None, "encrypted key: bad passphrase retried")
    s.expect(r"Enter passphrase for key")
    s.send(PASSPHRASE + "\r")
    check(s.shell_ready(), "encrypted key: connected")
    s.send("exit\r")
    s.wait()
    check(PASSPHRASE.encode() not in s.out and b"wrong-passphrase" not in s.out, "passphrase never echoed")
    s.close()

    out = subprocess.run(["ssh-agent", "-s"], capture_output=True, text=True).stdout
    agent = dict(os.environ)
    for k, v in re.findall(r"(SSH_AUTH_SOCK|SSH_AGENT_PID)=([^;]+);", out):
        agent[k] = v
    subprocess.run(["ssh-add", os.path.join(keys, "id_agent")], env=agent, capture_output=True)
    aenv = dict(env, SSH_AUTH_SOCK=agent["SSH_AUTH_SOCK"])
    s = Session(aenv, "agent")
    check(s.shell_ready() and b"passphrase" not in s.out and b"assword" not in s.out, "ssh-agent: connected without prompts")
    s.send("exit\r")
    s.wait()
    s.close()

    s = Session(env, "kbd")
    s.expect(r"\[y\]es")
    s.send("y\r")
    check(s.expect(r"Password: ?") is not None, "keyboard-interactive: PAM prompt drawn")
    s.send("bad-guess\r")
    check(s.expect("Permission denied, please try again") is not None, "keyboard-interactive: retry after a wrong answer")
    s.expect(r"Password: ?")
    s.send(PASSWORD + "\r")
    check(s.shell_ready(), "keyboard-interactive: connected")
    s.send("exit\r")
    s.wait()
    check(PASSWORD.encode() not in s.out, "keyboard-interactive: answer not echoed")
    s.close()

    s = Session(env, "dtpw")  # ~/.ssh/config alias from an Include'd file
    s.expect(r"\[y\]es")
    s.send("y\r")
    check(s.expect(r"dttest@127\.0\.0\.1's password: ") is not None, "password: prompt (alias via Include)")
    s.send(PASSWORD + "\r")
    check(s.shell_ready(), "password: connected")
    s.send("exit\r")
    s.wait()
    check(PASSWORD.encode() not in s.out, "password not echoed")
    s.close()

    s = Session(env, "dttest@127.0.0.1:2224")
    s.expect("password: ")
    s.send("\x03")
    check(s.wait() == 255, "Ctrl+C at a prompt cancels")
    s.close()

    s = Session(env, "dtbox")  # ~/.ssh/config Host with IdentityFile
    check(s.shell_ready(), "~/.ssh/config alias: HostName/User/Port/IdentityFile")
    s.send("exit\r")
    s.wait()
    s.close()

    print("pty")
    s = Session(env, "plain", rows=30, cols=100)
    s.shell_ready()
    check(s.run("stty size", r"30 100") is not None, "initial remote pty size 30x100")
    s.set_size(40, 132)
    time.sleep(0.3)
    check(s.run("stty size", r"40 132") is not None, "resize sends window-change (40x132)")
    check(s.run("echo $COLUMNS-$LINES", r"132-40") is not None, "remote shell sees SIGWINCH")
    s.send("kill -9 $$\r")
    st = s.wait()
    check(st == 137 or st == 255, f"killed remote shell -> exit {st}")
    s.close()

    print("forwarding")
    s = Session(env, "fwd")
    check(s.shell_ready(), "fwd profile connected")
    time.sleep(0.5)
    check(curl(f"http://127.0.0.1:18081/") == BODY, "-L: curl through localhost:18081")
    check(curl("--socks5-hostname", "127.0.0.1:18082", f"http://127.0.0.1:{HTTP_PORT}/") == BODY, "-D: curl via SOCKS5 (remote DNS)")
    check(curl("--socks4a", "127.0.0.1:18082", f"http://localhost:{HTTP_PORT}/") == BODY, "-D: curl via SOCKS4a")
    check(curl("--socks5", "127.0.0.1:18082", f"http://127.0.0.1:{HTTP_PORT}/") == BODY, "-D: curl via SOCKS5 (IPv4)")
    check(curl(f"http://127.0.0.1:18083/") == BODY, "-R: server port 18083 reaches our 127.0.0.1:18080")
    check(s.run(f"curl -s http://127.0.0.1:18083/x", r"hello from behind ssh") is not None, "-R: from inside the session")
    big = subprocess.run(["sh", "-c", f"for i in $(seq 1 20); do curl -s --max-time 5 http://127.0.0.1:18081/ & done; wait"], capture_output=True).stdout
    check(big == BODY * 20, "-L: 20 parallel connections")
    ctl = lambda *a: subprocess.run([BIN, "--ssh-ctl", str(s.pid), *a], capture_output=True, text=True, env=env).stdout
    lst = ctl("list")
    check("1 on L 18081:127.0.0.1:18080 | listening on 127.0.0.1:18081" in lst and "4 off L 18084" in lst, "control: list forwards")
    check(curl("http://127.0.0.1:18084/") == b"", "disabled forward is not listening")
    check(ctl("on", "4").startswith("ok on"), "control: enable forward 4")
    check(curl("http://127.0.0.1:18084/") == BODY, "runtime-enabled -L works")
    check(ctl("off", "1").startswith("ok off"), "control: disable forward 1")
    check(curl("http://127.0.0.1:18081/") == b"", "runtime-disabled -L refuses")
    check(ctl("toggle", "1").startswith("ok on") and curl("http://127.0.0.1:18081/") == BODY, "control: toggle back on")
    # Let keepalive replies (want_reply) queue up: a later tcpip-forward
    # request must not take one of them as its own answer.
    time.sleep(3.5)
    check(ctl("off", "3").startswith("ok off"), "control: disable -R")
    time.sleep(0.5)
    check(curl("http://127.0.0.1:18083/") == b"", "-R cancelled on the server")
    check(ctl("on", "3").startswith("ok on"), "control: re-enable -R")
    time.sleep(0.5)
    check(curl("http://127.0.0.1:18083/") == BODY, "-R listening again")
    check(ctl("add", f"L 18085:127.0.0.1:{HTTP_PORT}").startswith("ok 5") and curl("http://127.0.0.1:18085/") == BODY, "control: add a forward at runtime")
    check(ctl("status").startswith("connected fwd dttest@127.0.0.1:2222"), "control: status")
    check(s.shell_ready(), "shell still responsive after forwarding")
    s.send("exit\r")
    check(s.wait() == 0, "fwd session exit 0")
    s.close()
    check(not [f for f in os.listdir(os.path.join(rundir, "deathterminal")) if f.endswith(".sock")], "control socket removed on exit")

    s = Session(env, "dtbox", extra=["-L", f"18086:127.0.0.1:{HTTP_PORT}"])
    check(s.shell_ready() and curl("http://127.0.0.1:18086/") == BODY, "-L given on the command line")
    s.send("exit\r")
    s.wait()
    s.close()

    print("proxyjump")
    s = Session(env, "jump")
    check(s.shell_ready(), "ProxyJump: connected through the jump host")
    check(s.run("echo $SSH_CONNECTION", r"127\.0\.0\.1 \d+ 127\.0\.0\.1 2222") is not None, "ProxyJump: SSH_CONNECTION from the hop")
    s.send("exit 3\r")
    check(s.wait() == 3, "ProxyJump: exit status")
    s.close()

    print("reconnect")
    s = Session(env, "flaky")
    check(s.shell_ready(), "flaky: connected")
    s.send("echo PID=$PPID\r")
    m = s.expect(r"PID=(\d+)")
    if m:
        subprocess.run(["sudo", "-n", "kill", "-9", m.group(1).decode()])
    check(s.expect(r"reconnecting in \d+s", 15) is not None, "connection loss: reconnect notice")
    time.sleep(2.5)
    check(s.shell_ready(20), "reconnected: shell works again")
    s.send("exit\r")
    s.wait()
    s.close()

    print("secrets")
    leaked = []
    for root, _, files in os.walk(work):
        if "/keys" in root:
            continue
        for fn in files:
            p = os.path.join(root, fn)
            try:
                data = open(p, "rb").read()
            except OSError:
                continue
            if PASSWORD.encode() in data or PASSPHRASE.encode() in data:
                if not fn.endswith(".py") and "sshd" not in fn:
                    leaked.append(p)
    check(not leaked, f"no secret written under the test home/config/run dirs {leaked}")
    return agent


if __name__ == "__main__":
    sys.exit(main())
