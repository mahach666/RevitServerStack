# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-11-14

### Added

- The panel, the messages it sends and its console window are translated into English, Russian, German, French, Spanish, Brazilian Portuguese, Simplified Chinese and Japanese. The panel starts in the language of the browser (English when it is not available), a selector in the header changes it and the choice is remembered. The menu of the tray icon follows the language of Windows. Texts live in `panel/www/i18n/*.json`, used by the page and by PowerShell alike. How to fix or add a language: [CONTRIBUTING.md](CONTRIBUTING.md#translations).
- Self-checks of the translations: every catalog has the keys, placeholders and markup of English, no text is left in code, every key is used, and the tray menu has all languages.
- Documentation site at <https://mahach666.github.io/RevitServerStack/> (built with docfx from the READMEs), a logo, and links to DeepWiki.
- GitHub Actions: CI runs the self-checks and builds the launcher on every push and pull request; a pushed tag `vX.Y.Z` builds the release archive and publishes the GitHub release. How to cut a release: [CONTRIBUTING.md](CONTRIBUTING.md).
- Optional integrity check of the Autodesk installers: when `RS<year>_INSTALLER_SHA256` is set (or `--build-arg INSTALLER_SHA256=...` is given to `docker build`), the Dockerfiles compare the downloaded installer with that SHA-256 and fail the build on a mismatch. No hashes are pinned in the repository, see "Verifying the installers" in the README.
- Self-checks for the panel back end: saving settings, the settings check at start-up, port 808, `$` in paths of the generated compose files, static paths with `:`, job ids, the result of Start all and Stop all, the job runner (exit code, log, `%` in a command line, cancel), the session token.

### Changed

- Upgrade note: the installer step of the Dockerfiles of all eight versions changed (the optional integrity check), so Docker does not reuse the cached installer and later layers of images built before this update. The first build after updating runs the installer again (the images are about 14 GB); later builds use the cache. The check cannot be moved to a separate step to avoid this: any new step in front of the installer changes the cache chain too, and a step after it would run after the installation.
- The console window of the panel is no longer Russian only: it speaks the language of Windows.
- The English README names buttons and settings as the English interface does, instead of the Russian ones.

### Fixed

- Saving settings with a partial body (or a body that is not a JSON object) reset every setting not mentioned to its default. It now changes only what the body names and refuses a body that is not an object.
- A hand-edited `panel.config.json` with an invalid value (a port that is not a number, a bad context or project name) was not checked at start-up and crashed the panel with a raw .NET error. It is now checked like a save; an invalid file is reported, kept as `panel.config.json.invalid.bak` (the next save overwrites the file) and the default settings are used.
- Settings check: host port 808 is refused when a version needs 808 for Revit, and a disabled version no longer counts as an owner of port 808.
- A `$` in the models folder or in the path of the repository was interpolated by docker compose and mounted another folder. It is now escaped in the generated compose files.
- A request for a static path with `:` (`/C:/x`, `/index.html::$DATA`) answered HTTP 500 with the text of the .NET exception; it answers 404 now.
- Cancelling a job accepted any id and always reported success. The id is validated like the one of the log request, and a job whose process could not be stopped is no longer marked cancelled; the page says when a cancel did not happen.
- A malformed JSON body was reported as an empty body or as missing fields; it is now answered with "not valid JSON".
- The session token came from a time-seeded generator; it is now 32 random bytes of the system's cryptographic generator, and it is compared in constant time.
- A `%` in a path (for example a repository in a folder named `x%TEMP%y`) was expanded by cmd.exe in the job wrapper and corrupted the docker command.
- Start all and Stop all answered `ok: true` even when every target failed; they now answer `ok: false` with HTTP 409 when any target failed.
- The documented run without the panel failed on a fresh clone because `samples\rs<year>` did not exist; the README now creates it first.
- The log of a job could repeat or lose lines when two requests overlapped, and a single failed request stopped the live log and hid the Cancel button. Requests are now one at a time, and a failure is retried and reported after several in a row.
- The page stayed blank without a word when the language files could not be loaded; it now says so and still starts.
- Exit in the tray menu froze the icon for 3 seconds and then killed the panel, leaving its address file behind, and a second start could then open a dead address. The panel is stopped at once, and the address file is removed on exit and when the panel fails.
- Settings did not open when docker had exactly one context: the list of contexts was sent as a single string, not as a list.

## [1.1.0] - 2026-10-15

Docker on another computer.

### Added

- The panel works with remote docker contexts (`ssh://`, `tcp://`). Settings has a form that creates such a context and optional address fields. Browser links, readiness checks and the nginx upstream use the address of the server; for an ssh alias the real host name is resolved with `ssh -G`.
- With a remote engine the models folder is a path on the server: it is not created from the panel's machine, and a version whose folder is not an absolute path outside this repository is refused with an explanation. The folder has to exist already, because the Docker engine for Windows does not create a missing bind source; the panel says so in the settings, in its refusal and after a failed start. The Docker Desktop indicator and its buttons are hidden when no engine is local.
- The proxy can run on a remote Linux engine.

### Changed

- The generated proxy compose file no longer bind-mounts `nginx.conf`: the config is an environment variable that the container writes out itself. A bind mount names a path on the machine of the engine, so with a remote engine nginx would have found a missing path instead of the file.

### Fixed

- Names and addresses of docker contexts and the project name were checked with `$`, which also matches before a trailing newline. A newline would have split the line of a job wrapper. They are now checked with `\z`.
- A long docker error no longer stretches the status bar of the panel: it is cut and the full text is in the tooltip. The page no longer asks for `favicon.ico`.

### Notes

- Checked on a real remote Windows engine (Docker Desktop with Windows containers on another PC, reached over ssh): the images of Revit Server 2026 (2026.4) and 2027 build, start, answer on the admin page and in the REST service (roles Accelerator, Host and Admin), accept connections on port 808, and restart, stop and are removed from the panel. This was the first run of those two Dockerfiles. A Revit client was not connected.
- The proxy was checked on a real remote Linux engine: it started from the panel, routed by year, answered 404 for an unknown year, passed `nginx -t` and was removed from the panel.

## [1.0.0] - 2026-10-15

First public release.

### Added

- `RevitServerStack.exe`: a tray icon that starts the panel without a console window, opens it in the browser and stops it on exit. The panel stops by itself if the icon process dies. Built by `launcher/Build.ps1` with the C# compiler that ships with Windows; `launcher/Build.ps1 -Release` also writes the release archive, its SHA-256 and the release notes.
- Control panel (`Start-Panel.cmd`, `panel/`): start, stop, restart, rebuild and remove every Revit Server version and the proxy, live docker output, job history, settings.
- Revit Server 2026 (update 2026.4) and 2027: Dockerfiles, compose samples and nginx routes. Autodesk ships them in a new format, so the Dockerfiles unpack the installer with 7-Zip (pinned version, checked SHA-256) instead of running it. The base image is .NET Framework 4.8.
- Reverse proxy: nginx on one port, routing by the version year in the URL. The panel generates its config and compose file.
- Option to publish port 808 (WCF net.tcp) for the one version that serves Revit clients.
- Self-checks of the panel: `panel/tests/Invoke-Tests.ps1`.
- README in English and Russian, `CHANGELOG.md`, `CREDITS.md`, `CONTRIBUTING.md`.

### Changed

- The project is renamed from revit-server-docker to Revit Server Stack (repository `RevitServerStack`).
- `.gitignore` is cut down from the generic Visual Studio template to what this project needs.
- `.gitattributes` keeps CRLF for `.cmd` and `.ps1` files.
- `panel/server.ps1` takes two new optional parameters, `-UrlFile` and `-ParentPid`, used by the tray launcher. Running it by hand works as before.

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

- The Dockerfiles for 2020 to 2025 are unchanged from [dosymep/revit-server-docker](https://github.com/dosymep/revit-server-docker).
- The Dockerfiles for 2026 and 2027 were written against the downloaded installers: the MSI properties, file layout and IIS names were read from them, and the unpacking step was run on the host. No image was built for this release.
- The existing names are kept so that images that are already built stay in use: compose project `samples`, containers `rs<year>` and `revit-proxy`, models in `samples/rs<year>`.

[1.2.0]: https://github.com/mahach666/RevitServerStack/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/mahach666/RevitServerStack/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/mahach666/RevitServerStack/releases/tag/v1.0.0
