# OpenSSH 10.5p1 for SCO OpenServer 5

A working build of [OpenSSH](https://www.openssh.com/) **10.5p1** (August 2026)
for **SCO OpenServer 5.0.7**, replacing the `OpenSSH_4.3p2 / OpenSSL 0.9.7i`
that SCO shipped in 2005.

```
$ ssh -V
OpenSSH_10.5p1, OpenSSL 3.5.0 8 Apr 2025

$ ssh root@sco-box                      # no legacy options. none.
$ scp bigfile.tar.gz root@sco-box:/u1/  # 50 MB verified byte-identical
```

Negotiates `sntrup761x25519-sha512` post-quantum key exchange with an ed25519
host key and `chacha20-poly1305`, and still accepts your existing RSA keys.

## Why

The stock OpenSSH on OpenServer 5.0.7 is from 2006, on a crypto library from
2005. Every modern client needs a pile of overrides to talk to it:

```
KexAlgorithms +diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha1
HostKeyAlgorithms +ssh-rsa,ssh-dss
PubkeyAcceptedAlgorithms +ssh-rsa
Ciphers +aes128-cbc,3des-cbc
MACs +hmac-sha1
```

Those overrides only work while the client still *contains* the old
algorithms. OpenSSH 8.8 disabled `ssh-rsa` by default in 2021; when a future
release removes it rather than merely disabling it, access breaks on a day
nobody chose. This is a convenience and availability problem as much as a
security one.

With this build, all of the above comes out of `~/.ssh/config`.

## Install

> **Fresh SCO box?** Install
> [curl with TLS](https://github.com/tachytelic/curl-7.88.1-for-SCO-OpenServer-5)
> first. The full set of builds is indexed at
> [tachytelic.net](https://tachytelic.net/2017/07/sco-openserver-5-binaries/).

### Which download

| Asset | Use it if |
|---|---|
| **`openssh-10.5p1-sco.tar.gz`** | **Almost certainly this one.** Supports RSA, ECDSA and ed25519, so existing keys keep working. |
| `openssh-10.5p1-sco-minimal.tar.gz` | You want the smallest possible attack surface and are willing to reissue every key as ed25519. |

Both are statically linked and self-contained: **neither needs OpenSSL, Perl or
anything else installed on the target machine.** The difference is what was
linked in at build time. See [Limitations](#limitations-of-the-minimal-build)
for what the minimal build gives up.

See **[INSTALL.md](INSTALL.md)** for the full procedure on a box that already
runs SCO's ssh. The two coexist: this installs under `/usr/local`, SCO's lives
under `/opt/K/SCO/ssh/`, and nothing in SCO's tree is touched.

Short version:

```sh
/etc/groupadd -g 201 sshd
/etc/useradd -u 201 -g 201 -d /var/empty -s /bin/false -c "sshd privsep" sshd
mkdir -p /var/empty && chown root:sys /var/empty && chmod 755 /var/empty
cd / && gunzip -c openssh-10.5p1-sco.tar.gz | /usr/bin/tar xf -
/usr/local/bin/ssh-keygen -A
/usr/local/sbin/sshd -f /usr/local/etc/sshd_config
```

For startup at boot, install `openssh.init` as `/etc/init.d/openssh` and link
it to `/etc/rc2.d/S86openssh` and `/etc/rc0.d/K85openssh`. The ordering is
required: S86 puts it after `S85tcp`, which starts the PRNGD that supplies all
of sshd's entropy.

## Two things specific to this platform

### `IPQoS none` is mandatory

**Without it, every transfer over about 8 KB is silently truncated**, and some
connections fail outright. The shipped `sshd_config` sets it; if you write your
own, do not omit it.

OpenSSH 7.8 (commit `5ee8448ad`, April 2018) changed the default DSCP marking:

```c
-  options->ip_qos_interactive = IPTOS_LOWDELAY;
+  options->ip_qos_interactive = IPTOS_DSCP_AF21;
-  options->ip_qos_bulk       = IPTOS_THROUGHPUT;
+  options->ip_qos_bulk       = IPTOS_DSCP_CS1;
```

Those values are set on the socket with `setsockopt(IP_TOS)`, and OpenServer's
TCP stack mishandles both of them:

| `IPQoS` | 1 MB transfer |
|---|---|
| `lowdelay throughput` (pre-7.8 default) | works |
| `af21 cs1` (7.8+ default) | connection dies |
| `lowdelay cs1` | truncates at 8192 bytes |
| `af21 throughput` | connection dies |
| **`none`** | **works** |

Every OpenSSH from 7.8 onward is affected. `IPQoS lowdelay throughput` also
works; `none` is cleaner, since it tells sshd not to set TOS at all.

### Entropy comes from PRNGD

OpenServer has **no `/dev/urandom` and no `/dev/random`**. This build is
configured with `--with-prngd-socket=/etc/egd-pool` and takes its seed from the
PRNGD daemon that SCO's own ssh package ships.

PRNGD is started by `/etc/rc2.d/S85tcp`, independently of the ssh package and
of the `SECURESHELL` switch, so disabling SCO's sshd does not take it with it.
If PRNGD is not running, sshd fails closed on every connection.

## Limitations of the minimal build

The default build has no algorithm limitations worth listing: RSA, ECDSA,
ed25519, ML-DSA, DH, ECDH, ML-KEM, AES-GCM, AES-CTR, AES-CBC, 3DES and
chacha20-poly1305 are all present.

The **minimal** build is `--without-openssl`, which means **ed25519 keys only**:
no RSA and no ECDSA, for host keys or user keys, and no DH/ECDH key exchange or
AES-GCM. Available there: `ssh-ed25519`, `ssh-mldsa44-ed25519@openssh.com`,
`curve25519-sha256`, `sntrup761x25519-sha512`, `mlkem768x25519-sha256`,
`chacha20-poly1305` and AES-CTR.

If you pick it, plan for:

* **Old clients cannot connect.** ed25519 needs OpenSSH 6.5 (2014) or
  PuTTY 0.68 (2017). Other OpenServer boxes running the stock 4.3p2 cannot
  connect as clients at all.
* **RSA host key pins must be reissued**: `known_hosts`, monitoring, backup
  jobs.
* **Older embedded SSH libraries** will fail, particularly Java stacks such as
  JSch, which are RSA/DH only.

There is no speed reason to prefer either. Measured on the same host, best of
three 200 MB transfers over the virtual bridge:

| Cipher | minimal | with OpenSSL |
|---|---|---|
| chacha20-poly1305 | 36 MB/s | 37 MB/s |
| aes128-ctr | 36 MB/s | 39 MB/s |

## What is verified

On OpenServer 5.0.7 (build 66886) under Proxmox:

* Public-key authentication, command execution, interactive sessions
* 50 MB `scp` round-trip, byte-identical
* 50 MB `sftp` transfer, byte-identical
* Around 25 MB/s throughput
* `sntrup761x25519-sha512` kex, ed25519 host key, chacha20-poly1305
* Automatic startup across a reboot, via the supplied `openssh.init`
* **Password authentication against the TCB**, and **non-root login**, tested
  from PuTTY with an ordinary account
* **Cutover to port 22** with SCO's sshd disabled, and a reboot afterwards to
  confirm it holds
* **RSA key authentication and RSA/ECDSA host keys** on the OpenSSL build,
  including a legacy stack of `diffie-hellman-group14-sha1` with an
  `rsa-sha2-256` host key and AES-CBC
* No core files after 24 sessions, so the OpenSSL teardown segfault seen in
  its own test suite does not reach sshd

Password auth is worth calling out: this build is vanilla upstream and carries
none of SCO's own `pmregister`/`request_license` patches to `session.c`, yet
the upstream `*-*-sco3.2v5*` block (`HAVE_SECUREWARE`, `-lprot`) authenticates
against `/tcb` correctly on its own.

Note that because SCO's licence enforcement patches are absent, this is worth
understanding before deploying on a licence-sensitive production machine.

## Building from source

**A stock OpenServer 5.0.7 cannot build this as it ships.** Prerequisites,
none of which come from SCO:

**1. A C99 compiler.** OpenServer ships GCC 2.95.3, which is C89 only; OpenSSH
requires C99-style variadic macros and will not configure without them. This
build used **GCC 3.4.6**.

**1a. OpenSSL 3.x, for the default variant only.** The stock 0.9.7i is far
below the 1.1.1 that OpenSSH 10.x requires. Building OpenSSL in turn needs
Perl 5.10+, because its `Configure` opens with `use 5.10.0;` and OpenServer
ships 5.8.8. So the full chain is:

```
Perl 5.38.2  ->  OpenSSL 3.5.0  ->  OpenSSH 10.5p1 with RSA and ECDSA
```

* https://github.com/tachytelic/Perl-5.38.2-for-SCO-OpenServer-5
* https://github.com/tachytelic/OpenSSL-3.5.0-for-SCO-OpenServer-5

`./build.sh --minimal` skips all of that and needs only the compiler.

**2. A way to get the tarball onto the box.** The stock networking tools cannot
reach a modern host over TLS:

| Stock tool | Result against the OpenSSH CDN |
|---|---|
| curl 7.15.1 (OpenSSL 0.9.7i) | `SSL23_GET_SERVER_HELLO: unknown protocol` |
| GNU wget 1.8.2 (2002) | no TLS 1.2, does not even accept `--no-check-certificate` |

So either `scp` the tarball across, or install
[**curl 7.88.1 with TLS**](https://github.com/tachytelic/curl-7.88.1-for-SCO-OpenServer-5)
first, which is the bootstrap entry point for all of these builds. `build.sh`
attempts the download and stops with instructions if it fails.

The rest of the userland these builds assume is indexed at
[tachytelic.net](https://tachytelic.net/2017/07/sco-openserver-5-binaries/).

Everything else the build needs **is** stock: `gtar` and `gmake` in
`/usr/gnu/bin`, `patch` and `/bin/sh` from the SCO package tree, and `strip` in
`/usr/ccs/bin`.

With those in place:

```sh
CC=/usr/local/bin/gcc-3.4.6 ./build.sh              # default, with OpenSSL
CC=/usr/local/bin/gcc-3.4.6 ./build.sh --minimal    # ed25519 only
```

Run it on the SCO box in a writable directory on `/u1`. It applies the patch,
configures, builds, installs to `./install/` and prints the packaging command.
The only source change is one hunk in `patches/`, an `S_ISSOCK` fallback:
OpenServer has neither `S_ISSOCK` nor `S_IFSOCK`, and reports AF_UNIX sockets
with the `S_IFIFO` type bits.

**Verified** end to end from a directory containing nothing but `build.sh` and
`patches/`, and the resulting package is what is published here. Note that the
machine it was verified on already had GCC 3.4.6 and a modern curl available,
per the prerequisites above.

## Upstream notes

Two things found while getting this working, both worth knowing if you build
other OpenSSH versions here:

1. **The IPQoS regression** above, bisected to `5ee8448ad`. Arguably
   OpenServer's stack is at fault, but the failure mode is a silent truncation
   at 8 KB, which is unpleasant to diagnose.
2. **OpenSSH 7.8p1 and 7.9p1 do not compile** with `--with-prngd-socket`.
   `entropy.c` is missing a closing parenthesis in `rexec_recv_rng_seed()`. The
   block only compiles when `OPENSSL_PRNG_ONLY` is undefined, which is why it
   shipped broken across two releases.

## Licence

The build script and patch here are MIT, see [LICENSE](LICENSE). OpenSSH itself
is under its own licence, see the `LICENCE` file in the upstream tarball.
