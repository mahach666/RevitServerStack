# Contributing

Bug reports and pull requests are welcome.

## Before you open a pull request

1. Run the self-checks. They need Windows PowerShell 5.1 and no docker:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File panel\tests\Invoke-Tests.ps1
   ```

2. Add a check to `panel/tests/Invoke-Tests.ps1` when you change how the panel behaves.
3. Add a line about the change to `CHANGELOG.md`.

## Rules for the panel code

- Windows PowerShell 5.1 only: no ternary, no `??`, no `?.`.
- `.ps1` files are saved as UTF-8 with BOM and CRLF line endings. Without the BOM, PowerShell 5.1 reads the Russian messages as garbage.
- The panel UI is in Russian, code and comments are in English.
- No dependencies and no build step. The panel must run from a plain checkout.
- Everything that reaches a command line (names, paths, docker arguments) goes through `ConvertTo-CliArg` and is validated in `Test-PanelConfig`.
- Keep the names `rs<year>`, `revit-proxy` and the compose project `samples`. Changing them makes docker rebuild images that already exist.

## Dockerfiles

An image build takes 20 to 45 minutes and cannot be covered by the self-checks, so say in the pull request which versions you built and started. Do not commit installers or models: `*.exe` and `samples/rs<year>/` are ignored on purpose.
