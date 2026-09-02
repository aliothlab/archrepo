#!/usr/bin/bash
# Signs everything the matrix produced, folds it into the database and syncs the
# release. Single job on purpose: the database and the release are not shardable.
set -euo pipefail

: "${REPO:?}" "${TAG:?}" "${GPG_PRIVATE_KEY:?}"
GPG_PASSPHRASE=${GPG_PASSPHRASE:-}

shopt -s nullglob
install -dm755 out
cd out
pkgs=(*.pkg.tar.zst)
((${#pkgs[@]})) || { printf 'nothing to publish\n'; exit 0; }

export GNUPGHOME=/tmp/gnupg
install -dm700 "$GNUPGHOME"
printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --import
keyid=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')
[[ -n $keyid ]] || { printf '::error::no secret key in GPG_PRIVATE_KEY\n'; exit 1; }

sign() {
	printf '%s' "$GPG_PASSPHRASE" |
		gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
			--local-user "$keyid" --detach-sign --no-armor "$1"
}

# repo-add insists on a database archive extension; the release carries the
# names pacman fetches.
db=$REPO.db.tar.zst
files=$REPO.files.tar.zst
if [[ -f $REPO.db ]]; then mv "$REPO.db" "$db"; fi
if [[ -f $REPO.files ]]; then mv "$REPO.files" "$files"; fi
rm -f "$REPO.db.sig" "$REPO.files.sig"

for f in "${pkgs[@]}"; do sign "$f"; done
repo-add -q --include-sigs "$db" "${pkgs[@]}"
sign "$db"
sign "$files"
mv -f "$db.sig" "$REPO.db.sig"
mv -f "$files.sig" "$REPO.files.sig"
mv -f "$db" "$REPO.db"
mv -f "$files" "$REPO.files"

gh release view "$TAG" >/dev/null 2>&1 ||
	gh release create "$TAG" --title "$REPO ($TAG)" --notes 'pacman repository, updated by CI.'
gh release upload "$TAG" --clobber \
	"${pkgs[@]}" "${pkgs[@]/%/.sig}" \
	"$REPO.db" "$REPO.db.sig" "$REPO.files" "$REPO.files.sig"

# The database is the only record of what the repository still offers; anything
# else on the release is a superseded build.
mapfile -t keep < <(bsdtar -xOf "$REPO.db" '*/desc' |
	awk '/^%FILENAME%$/ { getline; print; print $0 ".sig" }')
keep+=("$REPO.db" "$REPO.db.sig" "$REPO.files" "$REPO.files.sig")
gh release view "$TAG" --json assets -q '.assets[].name' | while read -r asset; do
	[[ " ${keep[*]} " == *" $asset "* ]] || gh release delete-asset "$TAG" "$asset" --yes
done
