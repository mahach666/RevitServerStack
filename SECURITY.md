# Security policy

## Supported versions

Security fixes are made on the latest release only.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub private vulnerability reporting: open the Security tab of the repository and choose "Report a vulnerability". Include the version of Revit Server Stack, what you did and what happened. Do not send files with confidential content, logs with tokens or Autodesk installers.

You can expect an acknowledgement within a few days. Fixes are released as soon as they are verified, and the report is credited unless you prefer otherwise.

## Scope

Problems that matter most:

- a web page or a local program that can drive docker through the control panel without the session token, or reach the panel through another Host header;
- a path or a name that reaches a command line, a compose file or the file system without being validated (command injection, path traversal in the panel);
- a release archive that contains local data, or a Dockerfile step that runs unverified code when `INSTALLER_SHA256` is set.

Out of scope: the Autodesk installers and Revit Server itself, and exposure of the Revit Server ports to a network, which is how the stack is meant to be used (see "Security" in the README).
