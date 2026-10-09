# Changelog

What changed in each version of meshlink, newest first. Versions follow
[SemVer](https://semver.org/); dates are YYYY-MM-DD.

## Unreleased

### Changed

- Where to install OpenSSH Server on the PC is now given as **Win + R**,
  `ms-settings:optionalfeatures`, in the READMEs, the setup guide, the hint of
  `prepare-windows.ps1` and the plug-in's error message. The menu path
  "Settings → Apps → Optional features" does not exist on every Windows 10.

## 0.3.0-dev - 2026-10-09

Demo prerelease: the Mac package and the Rhino plug-in's package, with the same
version number. Tested on one Windows 10 PC with UAC off only; Windows 11 and a
fresh PC are not tested yet. Pairing was planned as 0.2 and ships here; there
will be no separate 0.1.0 or 0.2 release, and the first stable release will be
0.3.0.

### Added

- Pairing: `meshlink pair` on the Mac and a Rhino
  plug-in on the PC (commands `MeshlinkPair`, `MeshlinkOptions`,
  `MeshlinkUnpair`) replace the manual key and fingerprint steps of `setup`.
  Both screens show the same six-digit code. See the Pairing section of the
  README and [docs/pairing.md](docs/pairing.md).
- The plug-in's Yak package is attached to the release (drag it onto Rhino);
  `scripts/package-yak.sh` builds it. It is not on the public Yak server.
- `prepare-windows.ps1 -ResultFile` writes a machine-readable result, and
  `-RemoveKey` removes a Mac's key without touching anything else.
- Tests run on GitHub Actions (macOS, with the system bash 3.2) for every push
  to `main` and every pull request.

### Changed

- `meshlink client codex` edits `~/.codex/config.toml` in place. For an
  existing entry only its `command` and `args` lines change, so its
  environment, startup timeout, tool approvals and the file's comments are
  kept. Codex reads the result back, and a file it cannot read is restored
  from the backup.
- The tunnel script stops with exit code 3 when ssh may not use the network
  at all (`Operation not permitted`, for example inside an agent's sandbox),
  instead of retrying forever.
- The report of `prepare-windows.ps1` ends with the `meshlink client codex`
  step and the exact command Codex will run, without `-l`.

### Fixed

- `setup` gives new keys a fixed comment rather than `user@host`, and a rerun
  without `--key` reuses the key of the existing Host entry.
- Error text from the PC ends with a newline.

## 0.1.0-dev - 2026-10-02

First prerelease.

- `meshlink` command with `setup`, `client codex`, `doctor`,
  `windows-script`, `tunnel`, `uninstall` and `version`.
- `install.sh` and `uninstall.sh` for `~/.local`; release tarball with a
  SHA-256 file.
- `scripts/prepare-windows.ps1` to prepare the PC in one elevated run.
- Setup guide for both connection options
  ([docs/remote-setup.md](docs/remote-setup.md)).
