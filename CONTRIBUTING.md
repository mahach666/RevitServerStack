# Contributing

Bug reports and pull requests are welcome.

## Before you open a pull request

1. Run the self-checks. They need Windows PowerShell 5.1 and git, and the docker CLI (not a running engine) for two checks:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File panel\tests\Invoke-Tests.ps1
   ```

2. Add a check to `panel/tests/Invoke-Tests.ps1` when you change how the panel behaves.
3. Add a line about the change to `CHANGELOG.md`.

## Rules for the panel code

- Windows PowerShell 5.1 only: no ternary, no `??`, no `?.`.
- `.ps1` files are saved as UTF-8 with BOM and CRLF line endings. Without the BOM, PowerShell 5.1 reads non-ASCII characters as garbage.
- Code and comments are in English. Text that a user sees (the panel, the messages the panel sends, the console window) does not live in code: it is a key in `panel/www/i18n/*.json`, see [Translations](#translations).
- No dependencies and no build step. The panel must run from a plain checkout.
- Everything that reaches a command line (names, paths, docker arguments) goes through `ConvertTo-CliArg` and is validated in `Test-PanelConfig`.
- Keep the names `rs<year>`, `revit-proxy` and the compose project `samples`. Changing them makes docker rebuild images that already exist.

## Translations

The panel, the messages it sends and its console window use one set of catalogs, `panel/www/i18n/<code>.json`, with a flat `key: text` list. The browser reads them with `t()` in `app.js` and PowerShell with `T` in `panel/lib/I18n.ps1`. `en.json` is the source of truth: every other catalog must have exactly its keys, the same `{0}` placeholders and the same `<code>` markup (the self-checks verify this, and that no Cyrillic is left in code). A missing key falls back to English.

- Fix a translation: edit the text in `panel/www/i18n/<code>.json`.
- New text: add the key to every catalog, English first. Put it in HTML as `data-i18n="key"` (also `-html`, `-title`, `-placeholder`, `-aria-label` variants), in JavaScript as `t('key', arg)`, in PowerShell as `T 'key' $arg`. Never build a sentence from pieces, because word order differs between languages.
- New language: add `<code>.json` and an entry to `panel/www/i18n/index.json` (the code and the name of the language in itself). A browser or Windows language such as `zh-TW` finds the entry by its two-letter prefix, so nothing else is needed in the panel, and `Invoke-Tests.ps1` then checks the new catalog like the others.
- The menu of the tray icon cannot read the catalogs: its few lines are the `L10n` table in `launcher/RevitServerStack.cs`, one column per language, in the same order as `Languages`.

## The tray launcher and releases

`launcher/RevitServerStack.cs` is plain C# 5 (no `?.`, no string interpolation), built with the compiler that ships with Windows, so nobody needs Visual Studio or an SDK. The panel itself stays PowerShell and keeps running without the exe.

Build the exe, or the exe together with the release archive:

```
powershell -NoProfile -ExecutionPolicy Bypass -File launcher\Build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File launcher\Build.ps1 -Release
```

The version comes from the newest `## [x.y.z]` entry of `CHANGELOG.md`. `-Release` packs the files git would commit (tracked and new, ignored ones left out) plus the exe into `dist\RevitServerStack-<version>.zip`, and writes `.sha256` and `RELEASE_NOTES.md` next to it.

To publish: update `CHANGELOG.md`, commit, run the self-checks and the release build, then

```
git tag -a v<version> -m "Revit Server Stack <version>"
git push origin v<version>
gh release create v<version> dist\RevitServerStack-<version>.zip dist\RevitServerStack-<version>.zip.sha256 --title "Revit Server Stack <version>" --notes-file dist\RELEASE_NOTES.md
```

## Moving Revit Server 2026 or 2027 to a new update

Autodesk lists the current installer on [Revit Server 2026](https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/6jklbKtzdkgnbd4NTfV0zC.html) and [Revit Server 2027](https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/3Gfbmiwn7RrgauBEoTIfWn.html). The file name carries the update number for 2026 (`Revit_Server_2026_4_win_db.sfx.exe` is update 2026.4), and the page may ask to uninstall the previous update first. Rebuilding the image does that for you, because the new image is built from scratch and the models stay in the host folder.

1. Copy the link of the `.sfx.exe` from the page. Drop everything after `.exe` (`?_gl=...` is only analytics) and check it with `curl -I`.
2. In `src/rs<year>/Dockerfile` put the new file name into the `ADD` line and into the first `7zr.exe x` command, and the new link into the `ADD` line.
3. The archive inside the installer has a name with the same update number (`RVT_2026_4_NA_win_db_002_002.7z`). List it with `7zr.exe l <installer>` and put the exact name into both `7zr.exe x` commands.
4. Build the image from the panel ("Rebuild") and write in the pull request that it started.

## Dockerfiles

An image build takes 20 to 45 minutes and cannot be covered by the self-checks, so say in the pull request which versions you built and started. Do not commit installers or models: `*.exe` and `samples/rs<year>/` are ignored on purpose.
