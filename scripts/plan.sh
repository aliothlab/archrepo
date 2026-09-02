#!/usr/bin/bash
# Decides which packages are out of date and emits them as a job matrix.
set -euo pipefail

: "${REPO:?}"
FORCE=${FORCE:-false}
ONLY=${ONLY:-}
DB=out/$REPO.db

nvopts=()
if [[ -n ${GH_TOKEN:-} ]]; then
	printf '[keys]\ngithub = "%s"\n' "$GH_TOKEN" |
		install -Dm600 /dev/stdin "$HOME/.config/nvchecker/keyfile.toml"
	nvopts=(--keyfile "$HOME/.config/nvchecker/keyfile.toml")
fi

db_ver() {
	[[ -f $DB ]] || return 0
	bsdtar -tf "$DB" | awk -F/ -v n="$1" \
		'{ b = $1; sub(/-[^-]+-[^-]+$/, "", b); if (b == n) { print substr($1, length(b) + 2); exit } }'
}

entries=()

for dir in packages/*/; do
	pkgbase=${dir%/}
	pkgbase=${pkgbase##*/}
	[[ -z $ONLY || " $ONLY " == *" $pkgbase "* ]] || continue

	read -r pkgver pkgrel giturl < <(
		. "$dir/PKGBUILD"
		for s in "${source[@]-}"; do
			if [[ $s == *git+* ]]; then giturl=${s#*git+}; break; fi
		done
		printf '%s %s %s\n' "$pkgver" "$pkgrel" "${giturl-}"
	)

	if [[ -f $dir.nvchecker.toml ]]; then
		log=$(GIT_TERMINAL_PROMPT=0 nvchecker --file "$dir.nvchecker.toml" \
			--logger json "${nvopts[@]}" 2>&1) || true
		new=$(jq -rRn --arg n "$pkgbase" \
			'first(inputs | fromjson? | select(.name == $n and .version) | .version) // empty' <<<"$log")
		if [[ -z $new ]]; then
			printf '::warning::version check failed: %s: %s\n' "$pkgbase" \
				"$(jq -rRn --arg n "$pkgbase" \
					'first(inputs | fromjson? | select(.name == $n) | (.error // .event) | .[0:200]) // "no output"' <<<"$log")"
		elif (($(vercmp "$new" "$pkgver") > 0)); then
			pkgver=$new
			pkgrel=1
		fi
	fi

	tip=
	if [[ -n $giturl ]]; then
		branch=HEAD
		if [[ $giturl == *'#branch='* ]]; then
			branch=${giturl##*#branch=}
			branch=${branch%%[?&]*}
		fi
		tip=$(git ls-remote "${giturl%%\#*}" "$branch" | cut -c1-7) || true
		[[ -n $tip ]] || printf '::warning::cannot resolve %s (%s)\n' "$giturl" "$branch"
	fi

	cur=$(db_ver "$pkgbase")
	if [[ $FORCE != true && -n $cur ]]; then
		if [[ -n $tip ]]; then
			if [[ $cur == *"g$tip"* ]]; then
				printf 'up to date: %s %s\n' "$pkgbase" "$cur"
				continue
			fi
		elif (($(vercmp "$cur" "$pkgver-$pkgrel") >= 0)); then
			printf 'up to date: %s %s\n' "$pkgbase" "$cur"
			continue
		fi
	fi

	printf 'build: %s %s\n' "$pkgbase" "$pkgver"
	entries+=("$(jq -cn --arg b "$pkgbase" --arg v "$pkgver" '{pkgbase: $b, pkgver: $v}')")
done

printf 'packages=[%s]\n' "$(IFS=,; printf '%s' "${entries[*]}")" \
	>>"${GITHUB_OUTPUT:-/dev/stdout}"
