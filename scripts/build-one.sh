#!/usr/bin/bash
# Builds one package in a container that holds nothing but base-devel and the
# package's own makedepends, which is what makes it a clean chroot.
set -euo pipefail

pkgbase=${1:?}
newver=${2-}
builddir=/tmp/build

asb() { sudo -H -u builder "$@"; }

pacman -Syu --noconfirm --needed pacman-contrib

useradd -m builder
printf 'builder ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/builder
install -dm755 out srcdest "$builddir"
chown -R builder:builder out srcdest "$builddir" "packages/$pkgbase"

# A package that opts out of debug gets no prefix map from makepkg, and $srcdir
# then reaches __FILE__ and panic locations. Map what makepkg maps and nothing
# more: $srcdir only, so a $pkgdir reference still trips the check below.
cat >>/etc/makepkg.conf <<EOF
PKGDEST=$PWD/out
SRCDEST=$PWD/srcdest
BUILDDIR=$builddir
MAKEFLAGS="-j$(nproc)"
NPROC=$(nproc)
PACKAGER="$(gpg --show-keys --with-colons aliothlab.asc | awk -F: '/^uid:/{print $10; exit}')"
CFLAGS+=" -ffile-prefix-map=$builddir/$pkgbase/src=/usr/src/debug/$pkgbase"
CXXFLAGS+=" -ffile-prefix-map=$builddir/$pkgbase/src=/usr/src/debug/$pkgbase"
RUSTFLAGS+=" --remap-path-prefix=$builddir/$pkgbase/src=/usr/src/debug/$pkgbase"
EOF

cd "packages/$pkgbase"

cur=$(. ./PKGBUILD; printf '%s' "$pkgver")
if [[ -n $newver && $newver != "$cur" ]]; then
	asb sed -i "s/^pkgver=.*/pkgver=$newver/;s/^pkgrel=.*/pkgrel=1/" PKGBUILD
	asb updpkgsums
fi

asb makepkg --syncdeps --force --noconfirm

# pkgrel counts rebuilds of one pkgver; pkgver() has run by now, so VCS is covered too.
[[ $(. ./PKGBUILD; printf '%s' "$pkgver") == "$cur" ]] ||
	asb sed -i 's/^pkgrel=.*/pkgrel=1/' PKGBUILD

mapfile -t pkgs < <(asb makepkg --packagelist)
for f in "${pkgs[@]}"; do
	[[ -f $f ]] || continue
	# .BUILDINFO records BUILDDIR by design, so scan the payload only.
	refs=$(bsdtar -xOf "$f" --exclude .BUILDINFO --exclude .PKGINFO --exclude .MTREE |
		tr -c '[:print:]' '\n' |
		grep -o -- "${builddir}[^[:space:]]*" | sort -u | head -20) || true
	if [[ -n $refs ]]; then
		printf '::error::%s embeds the build path\n' "${f##*/}"
		printf '%s\n' "$refs"
		exit 1
	fi
done
