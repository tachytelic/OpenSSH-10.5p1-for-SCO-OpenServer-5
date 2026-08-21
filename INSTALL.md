# Installing OpenSSH 10.5p1 on a live OpenServer 5.0.7 box

This assumes the machine already runs **SCO's own OpenSSH**: the `SCO:ssh`
package, `OpenSSH_4.3p2 / OpenSSL 0.9.7i`, which is how OpenServer 5.0.7
ships.

The two never fight: ours lives entirely under `/usr/local`, SCO's under
`/opt/K/SCO/ssh/`. You run them side by side on different ports until you are
satisfied, then switch.

> **Before you start, open a console session**: the Proxmox VNC console, the
> ESXi console, or a physical terminal. Everything below is reversible, but the
> service you are replacing is the one you are probably logged in through.

---

## What you need

| | |
|---|---|
| The package | `openssh-10.5p1-sco.tar.gz`, relative paths, extracts from `/` into `/usr/local` |
| A free UID/GID | for the `sshd` privilege-separation account |
| **prngd running** | it already is; see [Entropy](#entropy-the-one-hard-dependency) |
| A key | RSA, ECDSA or ed25519 all work. If you took the `-minimal` package instead, ed25519 only |

## Entropy, the one hard dependency

OpenServer has **no `/dev/urandom` and no `/dev/random`**. This build gets its
entropy from **PRNGD** over the EGD socket at `/etc/egd-pool`, which is
compiled in via `--with-prngd-socket`.

PRNGD is started by `/etc/rc2.d/S85tcp` (which is `/var/opt/K/SCO/tcp/*/etc/tcp`)
at lines 194-216, **independently of the ssh package and of `SECURESHELL`**. So
disabling SCO's sshd later does not take PRNGD with it. Confirm before you
start:

```sh
ps -ef | grep in.prngd        # expect: /etc/in.prngd /etc/egd-pool
ls -l /etc/egd-pool
```

If PRNGD is not running, stop. sshd will fail closed on every connection.

---

## 1. Create the privsep account

Pick a free UID/GID. 201 was free here; check yours:

```sh
/etc/groupadd -g 201 sshd
/etc/useradd -u 201 -g 201 -d /var/empty -s /bin/false -c "sshd privsep" sshd
mkdir -p /var/empty && chown root:sys /var/empty && chmod 755 /var/empty
```

`/var/empty` must be owned by root and not group- or world-writable, or sshd
refuses to start.

## 2. Install the package

```sh
cd /
gunzip -c /tmp/openssh-10.5p1-sco.tar.gz | /usr/bin/tar xf -
/usr/local/sbin/sshd -V          # expect: OpenSSH_10.5p1, OpenSSL 3.5.0
```

Note `/usr/bin/tar`. There is no `/bin/tar` and no `gtar` on a stock box.

## 3. Generate host keys

```sh
/usr/local/bin/ssh-keygen -A
```

Produces RSA, ECDSA, ed25519 and mldsa44-ed25519 host keys. With the
`-minimal` package there will be no RSA or ECDSA host key; that is expected.

## 4. Configure

Edit `/usr/local/etc/sshd_config`. Three lines matter:

```
Port 2222
IPQoS none
PidFile /usr/local/etc/sshd.pid
```

The pidfile has to be somewhere that exists. sshd defaults to
`/var/run/sshd.pid`, and OpenServer has no `/var/run`, so without this it
silently never writes one and stopping the daemon cleanly is awkward. SCO's own
sshd uses `/etc/sshd.pid`, so this keeps out of its way.

**`IPQoS none` is not optional.** Without it every transfer over about 8 KB is
silently truncated and some connections fail outright. OpenSSH 7.8 changed the
default DSCP marking to AF21/CS1 and OpenServer's TCP stack mishandles both
values; see [README.md](README.md) for the detail. `IPQoS lowdelay throughput`
works too; `none` is cleaner.

Use `Port 2222` for now. You will move it to 22 at cutover.

## 5. Keys

Existing RSA and ECDSA keys keep working, so there is nothing to migrate.
Append your public key to `~/.ssh/authorized_keys` on the SCO box as usual
(`chmod 700 ~/.ssh`, `chmod 600 authorized_keys`).

The host key changes, because this is a different daemon with its own keys.
Anything pinning the old one needs re-pinning: `known_hosts`, monitoring,
backup jobs.

**If you took the `-minimal` package**, it supports ed25519 only. Reissue
client keys before cutover:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/sco_ed25519     # on each client
```

and note that other OpenServer boxes running the stock 4.3p2 will not be able
to connect as clients at all.

## 6. Start it alongside and test

```sh
/usr/local/sbin/sshd -t -f /usr/local/etc/sshd_config     # config check
/usr/local/sbin/sshd -f /usr/local/etc/sshd_config
netstat -an | grep 2222
```

From a client. **Note the complete absence of legacy options**:

```sh
ssh -i ~/.ssh/sco_ed25519 -p 2222 root@<host>
```

Copy a large file across with `scp` as well, then leave it running on 2222 for
as long as you want. SCO's sshd on 22 is untouched.

## 7. Cutover

Only when you are satisfied, and **with a console session open**.

```sh
# 1. stop SCO's sshd starting at boot (prngd is unaffected)
cp -p /etc/default/tcp /etc/default/tcp.pre-openssh
sed 's/^SECURESHELL=YES/SECURESHELL=NO/' /etc/default/tcp > /tmp/t && cp /tmp/t /etc/default/tcp

# 2. stop the running one. Match the command field exactly: a loose pattern
#    like grep /etc/sshd also matches OUR sshd, whose command line contains
#    /usr/local/etc/sshd_config, and would kill the daemon you just started.
kill `ps -ef | awk '$8 == "/etc/sshd" { print $2 }'`

# 3. move ours to port 22
sed 's/^Port 2222/Port 22/' /usr/local/etc/sshd_config > /tmp/c && cp /tmp/c /usr/local/etc/sshd_config

# 4. restart ours
kill `cat /usr/local/etc/sshd.pid`
/usr/local/sbin/sshd -f /usr/local/etc/sshd_config
```

**Test a fresh login from another terminal before closing the console.**

## 8. Start at boot

Install the supplied init script and link it into the run levels:

```sh
cp openssh.init /etc/init.d/openssh
chmod 755 /etc/init.d/openssh
chown root:sys /etc/init.d/openssh
ln -s /etc/init.d/openssh /etc/rc2.d/S86openssh
ln -s /etc/init.d/openssh /etc/rc0.d/K85openssh
```

The numbers matter. **S86 must be higher than S85tcp**, which is what starts
PRNGD; start before it and sshd has no entropy and fails closed on every
connection. **K85 must be lower than K96tcp**, so sshd stops before networking
is torn down. The script also waits up to 10 seconds for `/etc/egd-pool` to
appear, since PRNGD has only just been launched when it runs.

The script uses the `PidFile` set in section 4. It takes `start`, `stop`, `restart` and `status`:

```sh
/etc/init.d/openssh status
```

## Rollback

At any point:

```sh
kill `cat /usr/local/etc/sshd.pid`
cp -p /etc/default/tcp.pre-openssh /etc/default/tcp     # SECURESHELL=YES
/etc/sshd                                                # or reboot
```

Nothing in `/opt/K/SCO/ssh/` is touched at any stage, so SCO's sshd is always
one command away.

---

## What is verified, and what is not

**Verified on OpenServer 5.0.7 (build 66886):** build, install, host key
generation, public-key authentication as root, command execution, interactive
session, 50 MB `scp` round-trip byte-identical, 50 MB `sftp` byte-identical,
~25 MB/s, negotiating `sntrup761x25519-sha512` with an ed25519 host key and
chacha20-poly1305, **automatic startup across a reboot** with the init script
in section 8, **password authentication against the TCB** for an ordinary
non-root account tested from PuTTY, and the **cutover in section 7** on a live
box, including a reboot afterwards to confirm SCO's sshd stays disabled and
ours comes back on port 22.

**Not tested:**

* Anything relying on SCO's licence enforcement. Ours is vanilla upstream and
  does **not** carry SCO's `pmregister`/`request_license` changes to
  `session.c`, worth understanding before deploying on a licence-sensitive
  production box.
