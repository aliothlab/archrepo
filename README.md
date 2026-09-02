# aliothlab

A signed pacman repository for x86_64, rebuilt daily by GitHub Actions.
Packages and the database live in the `x86_64` release of this repository.

| package | source |
| --- | --- |
| `auth-thu` | [z4yx/GoAuthing](https://github.com/z4yx/GoAuthing) |
| `cloudcompare-git` | [CloudCompare/CloudCompare](https://github.com/CloudCompare/CloudCompare) |
| `honk` | [Glassyiris/honk](https://github.com/Glassyiris/honk) |
| `meshlab-git` | [cnr-isti-vclab/meshlab](https://github.com/cnr-isti-vclab/meshlab) |
| `rule-set-cn` | [aliothlab/rule-set](https://github.com/aliothlab/rule-set) |
| `sing-box-beta` | [SagerNet/sing-box](https://github.com/SagerNet/sing-box) |

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

`.github/workflows/build.yml` runs at 21:00 UTC as three stages, all inside
`archlinux:base-devel`:

1. `plan` downloads the current database, runs `nvchecker` for every package that
   ships a `.nvchecker.toml`, compares VCS packages against `git ls-remote`, and
   emits whatever is out of date as a job matrix;
2. `build` takes one job per package, in parallel. Each job is a fresh container
   holding nothing but `base-devel` and that package's `makedepends`, so an
   undeclared dependency fails the build instead of being borrowed from the
   package built before it. A package that embeds the build path is rejected;
3. `publish` signs the artifacts, folds them into the database with
   `repo-add --include-sigs`, uploads them, deletes release assets the database
   no longer lists, and commits the `pkgver`/checksum changes back.

`makepkg.conf` is only told where to put things and how much parallelism it has.
`debug`, `lto` and `strip` keep their Arch defaults; a package that needs
otherwise says so in its own `options=()`.

Run it by hand from the Actions tab: `force` rebuilds regardless of version,
`packages` limits the run to the pkgbases you name.

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
