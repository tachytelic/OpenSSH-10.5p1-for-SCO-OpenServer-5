#!/bin/sh
# Build OpenSSH 10.5p1 natively on SCO OpenServer 5.0.7.
#
# Run on the SCO machine, in a writable directory (use /u1, not /).
# Output: ./install/usr/local/... ready to be tarred up and extracted from /
# on the target machine.
#
# Needs a C99 compiler. SCO's stock /usr/gnu/bin/gcc is 2.95.3 and will not
# do; set CC to gcc 3.4.6 or newer, e.g.
#
#   CC=/usr/local/bin/gcc-3.4.6 ./build.sh

set -e

# Two variants:
#   (default)     linked against OpenSSL, supports RSA, ECDSA, DH/ECDH, AES-GCM
#   --minimal     --without-openssl, ed25519 only, much smaller attack surface
#
# The default needs OpenSSL 3.x installed, which itself needs Perl 5.10+:
#   https://github.com/tachytelic/OpenSSL-3.5.0-for-SCO-OpenServer-5
#   https://github.com/tachytelic/Perl-5.38.2-for-SCO-OpenServer-5
VARIANT=openssl
[ "$1" = "--minimal" ] && VARIANT=minimal

SCRIPT_DIR=`cd \`dirname "$0"\` && pwd`
VERSION=10.5p1
OPENSSL_DIR=${OPENSSL_DIR:-/usr/local/openssl-3.5.0}
TARBALL=openssh-${VERSION}.tar.gz
SRCDIR=openssh-${VERSION}
URL=https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/${TARBALL}

CC="${CC:-/usr/local/bin/gcc-3.4.6}"
export CC
PATH=/usr/local/bin:/usr/gnu/bin:/usr/ccs/bin:/usr/bin:/bin
export PATH

# Entropy: OpenServer has no /dev/urandom. sshd gets its seed from PRNGD
# over the EGD socket, which SCO's own ssh package already runs.
PRNGD_SOCKET=/etc/egd-pool

if [ ! -r "$PRNGD_SOCKET" ]; then
    echo "ERROR: $PRNGD_SOCKET not found."
    echo "PRNGD supplies all entropy on this platform; sshd cannot run without it."
    echo "It is normally started by /etc/rc2.d/S85tcp. Check: ps -ef | grep in.prngd"
    exit 1
fi

# Fetching needs TLS 1.2, which the stock tools cannot do: OpenServer ships
# curl 7.15.1 on OpenSSL 0.9.7i (fails with SSL23_GET_SERVER_HELLO) and GNU
# wget 1.8.2 from 2002. If you have not built a modern curl, copy the tarball
# across from another machine instead.
if [ ! -f "$TARBALL" ]; then
    if which curl >/dev/null 2>&1; then
        curl -kLO "$URL" || true
    elif which wget >/dev/null 2>&1; then
        wget --no-check-certificate "$URL" || true
    fi
fi

if [ ! -s "$TARBALL" ]; then
    rm -f "$TARBALL"
    echo "ERROR: could not download $TARBALL."
    echo
    echo "The stock OpenServer curl and wget are too old to negotiate TLS with"
    echo "modern hosts. Copy the tarball to this directory by other means:"
    echo
    echo "  scp $TARBALL sco-box:`pwd`/"
    echo
    echo "  $URL"
    exit 1
fi

rm -rf "$SRCDIR"
gtar xzf "$TARBALL" 2>/dev/null || tar xzf "$TARBALL"

# Old GNU tar does not understand pax headers and leaves these behind.
find "$SRCDIR" -name 'PaxHeaders*' -exec rm -rf {} + 2>/dev/null || true

cd "$SRCDIR"

echo "Applying SCO patch..."
patch -p1 < "$SCRIPT_DIR/patches/openssh-${VERSION}-sco.patch"

echo "Configuring ($VARIANT variant)..."
# --without-pam: OpenServer has no PAM. Authentication goes through the TCB
#   (SecureWare) instead; the upstream SCO block handles that.
if [ "$VARIANT" = "openssl" ]; then
    if [ ! -f "$OPENSSL_DIR/lib/libcrypto.a" ]; then
        echo "ERROR: no OpenSSL at $OPENSSL_DIR."
        echo "The stock 0.9.7i is far below the 1.1.1 OpenSSH 10.x requires."
        echo "Build it first (which needs Perl 5.10+ first):"
        echo "  https://github.com/tachytelic/OpenSSL-3.5.0-for-SCO-OpenServer-5"
        echo
        echo "Or build the minimal ed25519-only variant instead:"
        echo "  ./build.sh --minimal"
        exit 1
    fi
    SSL_ARGS="--with-ssl-dir=$OPENSSL_DIR"
else
    # --without-openssl uses OpenSSH's own ed25519, curve25519, ML-KEM and
    # chacha20-poly1305. No RSA, no ECDSA, no DH/ECDH kex, no AES-GCM.
    SSL_ARGS="--without-openssl"
fi

./configure \
    --prefix=/usr/local \
    $SSL_ARGS \
    --without-pam \
    --with-privsep-user=sshd \
    --with-prngd-socket="$PRNGD_SOCKET"

echo "Compiling..."
gmake

echo "Installing to $SCRIPT_DIR/install/..."
rm -rf "$SCRIPT_DIR/install"
gmake install-nokeys DESTDIR="$SCRIPT_DIR/install"

# Ship a config that works. Without IPQoS none, transfers over roughly 8 KB
# are silently truncated on this platform. See README.md.
CONF="$SCRIPT_DIR/install/usr/local/etc/sshd_config"
if [ -f "$CONF" ]; then
    grep -v '^IPQoS' "$CONF" > "$CONF.new"
    echo "" >> "$CONF.new"
    echo "# Required on OpenServer: the DSCP marking OpenSSH has defaulted to" >> "$CONF.new"
    echo "# since 7.8 breaks bulk transfer on this TCP stack. See README.md." >> "$CONF.new"
    echo "IPQoS none" >> "$CONF.new"
    mv "$CONF.new" "$CONF"
fi

echo "Stripping..."
find "$SCRIPT_DIR/install" -type f -perm -u+x -exec strip {} \; 2>/dev/null || true

echo
ls -l "$SCRIPT_DIR/install/usr/local/sbin/" "$SCRIPT_DIR/install/usr/local/bin/"
echo
"$SCRIPT_DIR/install/usr/local/sbin/sshd" -V || true
echo
echo "To package (run as root, and name the directories explicitly:"
echo "'make install' also creates var/empty under DESTDIR, and packaging bare"
echo "./ ./usr ./var entries would rewrite those directories' ownership on the"
echo "target machine when the archive is extracted from /):"
echo
if [ "$VARIANT" = "minimal" ]; then SUFFIX="-minimal"; else SUFFIX=""; fi
echo "  cd $SCRIPT_DIR/install && gtar cf - \\"
echo "      ./usr/local/bin ./usr/local/sbin ./usr/local/libexec \\"
echo "      ./usr/local/etc ./usr/local/share | gzip -9 > ../openssh-${VERSION}-sco${SUFFIX}.tar.gz"
echo
echo "Then see INSTALL.md. Do not skip the privsep account or IPQoS none."
