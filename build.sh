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

SCRIPT_DIR=`cd \`dirname "$0"\` && pwd`
VERSION=10.5p1
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

echo "Configuring..."
# --without-openssl: the newest OpenSSL on a stock box is 0.9.7i, and OpenSSH
#   10.x needs 1.1.1+. Building without it uses OpenSSH's own ed25519,
#   curve25519, ML-KEM and chacha20-poly1305 implementations instead, which is
#   what a modern client negotiates anyway. Costs RSA and ECDSA support.
# --without-pam: OpenServer has no PAM. Authentication goes through the TCB
#   (SecureWare) instead; the upstream SCO block handles that.
./configure \
    --prefix=/usr/local \
    --without-openssl \
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
echo "  cd $SCRIPT_DIR/install && gtar cf - \\"
echo "      ./usr/local/bin ./usr/local/sbin ./usr/local/libexec \\"
echo "      ./usr/local/etc ./usr/local/share | gzip -9 > ../openssh-${VERSION}-sco.tar.gz"
echo
echo "Then see INSTALL.md. Do not skip the privsep account or IPQoS none."
