# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-15

First public release.

### Added

- Control panel (`Start-Panel.cmd`, `panel/`): start, stop, restart, rebuild and remove every Revit Server version and the proxy, live docker output, job history, settings.
- Reverse proxy: nginx on one port, routing by the version year in the URL. The panel generates its config and compose file.
- Option to publish port 808 (WCF net.tcp) for the one version that serves Revit clients.
- Self-checks of the panel: `panel/tests/Invoke-Tests.ps1`.
- README in English and Russian, `CHANGELOG.md`, `CREDITS.md`, `CONTRIBUTING.md`.

### Changed

- The project is renamed from revit-server-docker to Revit Server Stack (`revit-server-stack`).
- `.gitignore` is cut down from the generic Visual Studio template to what this project needs.
- `.gitattributes` keeps CRLF for `.cmd` and `.ps1` files.

### Fixed

- The Dockerfiles in `src/` were never committed: the `.gitignore` pattern `rs20**/` meant for the models folders matched `src/rs<year>/` too, so a fresh clone could not build anything and the panel found no versions. The pattern is now anchored to `samples/`.
- `ConvertTo-CliArg` did not escape double quotes and did not protect a trailing backslash (the regular expressions matched a literal `*` and `+`). It now also quotes the cmd.exe characters `& | < > ^ ( )`.
- The panel accepted any text as compose project name and docker context name, and both end up on a cmd.exe command line. They are now validated.
- The static file check of the panel compares against the `www` folder with a trailing separator, so a sibling folder with the same prefix cannot pass it.

### Removed

- `samples/Start-Revit-2022.cmd` and `samples/Start-Revit-2025.cmd`: the panel replaces them, and they covered two versions out of six.
- The root `.dockerignore`: build contexts are `src/rs<year>/`, so it never applied.
- Empty placeholder `DELETEME.txt` files and IDE state.

### Notes

- The Dockerfiles are unchanged from [dosymep/revit-server-docker](https://github.com/dosymep/revit-server-docker). Images were not rebuilt for this release.
- The existing names are kept so that images that are already built stay in use: compose project `samples`, containers `rs<year>` and `revit-proxy`, models in `samples/rs<year>`.

[1.0.0]: https://github.com/mahach666/revit-server-stack/releases/tag/v1.0.0
