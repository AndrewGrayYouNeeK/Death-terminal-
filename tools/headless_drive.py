"""Drive `deathterminal --headless` through a pseudo-terminal and dump grid frames.

Usage: python3 tools/headless_drive.py SCRIPT.py
SCRIPT.py calls run([(bytes_to_send, seconds_to_wait, snapshot_label_or_None), ...]).
Used to check vim/less/htop/tmux/vttest output (see docs/VT_SUPPORT.md).
"""
import os, pty, sys, time, select
BIN=os.environ.get('DT_BIN', os.path.join(os.path.dirname(__file__), '..', 'zig-out', 'bin', 'deathterminal'))
def run(steps, rows=24, cols=80, label=''):
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ, SHELL='/bin/sh', PS1='$ ', HOME='/tmp/vthome', LANG='C.UTF-8')
        os.makedirs('/tmp/vthome', exist_ok=True)
        os.execve(BIN, [BIN, '--headless', '--no-ai'], env)
    buf = bytearray()
    def pump(t):
        end = time.time() + t
        while time.time() < end:
            r,_,_ = select.select([fd],[],[],0.05)
            if r:
                try: d = os.read(fd, 65536)
                except OSError: return False
                if not d: return False
                buf.extend(d)
        return True
    pump(1.0)
    frames = []
    for data, delay, snap in steps:
        if data: os.write(fd, data)
        pump(delay)
        if snap:
            s = bytes(buf).decode('utf-8','replace')
            i = s.rfind('\x1b[H')
            frame = s[i+3:]
            j = frame.rfind('\x1b[')
            frames.append((snap, frame[:j], frame[j:]))
    try: os.kill(pid, 9)
    except: pass
    os.waitpid(pid, 0)
    for name, f, cur in frames:
        print(f'===== {label} :: {name}  cursor={cur!r}')
        lines = f.split('\r\n')
        for n,l in enumerate(lines): print(f'{n:2}|{l.rstrip()}')
if __name__ == '__main__':
    exec(open(sys.argv[1]).read())
