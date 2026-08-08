# aliothlab

A signed pacman repository for x86_64, rebuilt daily by GitHub Actions.
Packages and the database live in the `x86_64` release of this repository.

| package | source |
| --- | --- |
| `kdae-git` | [olicesx/dae](https://github.com/olicesx/dae), branch `kdae` |
| `honk` | [Glassyiris/honk](https://github.com/Glassyiris/honk) |
| `rule-set-cn` | [aliothlab/rule-set](https://github.com/aliothlab/rule-set), installs `/usr/share/dae/{geosite,geoip}.dat` |

## Using the repository

Import and locally sign the key the packages are signed with:

```console
$ curl -fsSLO https://raw.githubusercontent.com/aliothlab/archrepo/main/aliothlab.asc
$ gpg --show-keys aliothlab.asc
# pacman-key --add aliothlab.asc
# pacman-key --lsign-key B4583DE83B85027DB16CC9F8F5AF33A86EB800A0
```

`gpg --show-keys` must print the fingerprint
`B458 3DE8 3B85 027D B16C  C9F8 F5AF 33A8 6EB8 00A0`; anything else means the
file is not the key this repository is signed with.

Append to `/etc/pacman.conf`:

```ini
[aliothlab]
SigLevel = Required
Server = https://github.com/aliothlab/archrepo/releases/download/$arch
```

Then `pacman -Syu`.

## How the daily build works

`.github/workflows/build.yml` runs at 21:00 UTC and inside `archlinux:base-devel`:

1. downloads the current database from the `x86_64` release;
2. runs `pkgctl version upgrade` for every package that ships a `.nvchecker.toml`,
   which rewrites `pkgver`, resets `pkgrel` and refreshes the checksums;
3. for VCS packages, compares `git ls-remote` against the commit hash in the
   published `pkgver` and skips the build when they match;
4. builds what is out of date with `makepkg -s`, detach-signs every artifact;
5. `repo-add -R --include-sigs` updates the database and drops superseded
   package files;
6. uploads the new artifacts, prunes assets no longer in the database, and
   commits the `pkgver`/checksum changes back.

Run it by hand from the Actions tab; the `force` input rebuilds everything
regardless of version.

## Required secrets

| secret | contents |
| --- | --- |
| `GPG_PRIVATE_KEY` | `gpg --armor --export-secret-keys <KEYID>` |
| `GPG_PASSPHRASE` | passphrase of that key, empty if it has none |

The public half is `aliothlab.asc` in the repository root. That key's uid also
becomes the `PACKAGER` field of every package; it needs no deliverable mailbox.

## Adding a package

Create `packages/<pkgbase>/` with the `PKGBUILD` and any local sources it
installs. For non-VCS packages add a `.nvchecker.toml` whose section name
matches the pkgbase — `pkgctl version setup` generates a starting point.
Everything else is automatic.
