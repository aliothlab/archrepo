#!/usr/bin/bash
# Runs inside archlinux:base-devel. Builds every out-of-date package under
# packages/, signs the results and updates the repository database in out/.
set -euo pipefail

: "${REPO:?}" "${HOST_UID:?}" "${HOST_GID:?}" "${GPG_PRIVATE_KEY:?}"
FORCE=${FORCE:-false}
GH_TOKEN=${GH_TOKEN:-}
GPG_PASSPHRASE=${GPG_PASSPHRASE:-}

WORK=/build
IN=$WORK/packages
OUT=$WORK/out
DB=$OUT/$REPO.db.tar.zst
FILES=$OUT/$REPO.files.tar.zst
GNUPGHOME=/tmp/gnupg

asb() { sudo -H -u builder "$@"; }

gpgb() { asb env GNUPGHOME="$GNUPGHOME" gpg "$@"; }

sign() {
	printf '%s' "$GPG_PASSPHRASE" |
		gpgb --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
			--local-user "$KEYID" --detach-sign --no-armor "$1"
}

db_ver() {
	[[ -f $DB ]] || return 0
	bsdtar -tf "$DB" | sed -n 's|/$||p' |
		awk -v n="$1" '{ b=$0; sub(/-[^-]+-[^-]+$/,"",b); if (b==n) { print substr($0,length(b)+2); exit } }'
}

pacman -Syu --noconfirm --needed devtools git nvchecker pacman-contrib

useradd -m builder
printf 'builder ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/builder
install -dm755 -o builder -g builder /tmp/build /tmp/srcdest "$OUT"
trap 'chown -R "$HOST_UID:$HOST_GID" "$WORK"' EXIT
chown -R builder:builder "$WORK"

install -dm700 -o builder -g builder "$GNUPGHOME"
printf '%s' "$GPG_PRIVATE_KEY" | gpgb --batch --quiet --import
KEYID=$(gpgb --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')
[[ -n $KEYID ]] || { echo "::error::no secret key in GPG_PRIVATE_KEY"; exit 1; }

cat >>/etc/makepkg.conf <<EOF
PKGDEST=$OUT
SRCDEST=/tmp/srcdest
BUILDDIR=/tmp/build
MAKEFLAGS="-j$(nproc)"
PACKAGER="$(gpgb --list-secret-keys --with-colons | awk -F: '/^uid:/{print $10; exit}')"
EOF

asb install -dm700 /home/builder/.config/nvchecker
printf '[keys]\ngithub = "%s"\n' "$GH_TOKEN" |
	asb install -m600 /dev/stdin /home/builder/.config/nvchecker/keyfile.toml

# repo-add insists on a database archive extension; the release carries the
# names pacman fetches.
if [[ -f $OUT/$REPO.db ]]; then mv "$OUT/$REPO.db" "$DB"; fi
if [[ -f $OUT/$REPO.files ]]; then mv "$OUT/$REPO.files" "$FILES"; fi
rm -f "$OUT/$REPO.db.sig" "$OUT/$REPO.files.sig"

built=()
failed=()

for dir in "$IN"/*/; do
	pkgbase=${dir%/}
	pkgbase=${pkgbase##*/}
	cd "$dir"

	if [[ -f .nvchecker.toml ]]; then
		asb pkgctl version upgrade || echo "::warning::version check failed: $pkgbase"
	fi

	unset -v pkgver pkgrel source
	. ./PKGBUILD

	# VCS packages carry no upstream version, so compare the remote tip against
	# the commit hash already encoded in the published pkgver.
	tip=
	for s in "${source[@]-}"; do
		[[ $s == *git+* ]] || continue
		u=${s#*git+}
		b=HEAD
		if [[ $u == *"#branch="* ]]; then
			b=${u##*#branch=}
			b=${b%%[?&]*}
		fi
		tip=$(git ls-remote "${u%%\#*}" "$b" | cut -c1-7)
		break
	done

	cur=$(db_ver "$pkgbase")
	if [[ $FORCE != true && -n $cur ]]; then
		if [[ -n $tip ]]; then
			if [[ $cur == *"g$tip"* ]]; then
				echo "up to date: $pkgbase $cur"
				continue
			fi
		elif (($(vercmp "$cur" "$pkgver-$pkgrel") >= 0)); then
			echo "up to date: $pkgbase $cur"
			continue
		fi
	fi

	echo "::group::$pkgbase"
	if asb makepkg -sf --noconfirm; then
		mapfile -t out < <(asb makepkg --packagelist)
		built+=("${out[@]}")
	else
		failed+=("$pkgbase")
		echo "::error::build failed: $pkgbase"
	fi
	echo "::endgroup::"
done

if ((${#built[@]})); then
	for f in "${built[@]}"; do sign "$f"; done
	asb repo-add -q -R --include-sigs "$DB" "${built[@]}"
	sign "$DB"
	sign "$FILES"
	mv -f "$DB.sig" "$OUT/$REPO.db.sig"
	mv -f "$FILES.sig" "$OUT/$REPO.files.sig"
	rm -f "$OUT/$REPO.db" "$OUT/$REPO.files"
	mv -f "$DB" "$OUT/$REPO.db"
	mv -f "$FILES" "$OUT/$REPO.files"
	printf '%s\n' "${built[@]##*/}" >"$WORK/built.txt"
fi

((${#failed[@]} == 0))
