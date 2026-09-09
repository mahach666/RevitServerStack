# revit-server-docker

This is experimental revit servers docker files.

## Control panel

A local web UI to start, stop, rebuild and configure every Revit Server version
and the reverse proxy, instead of running compose commands by hand.

```
Start-Panel.cmd
```

Double-click it (or run it from a terminal). It opens `http://localhost:8787/`
in the browser. Keep the console window open while you use the panel — closing
it stops the panel, not the containers.

Requirements: Windows PowerShell 5.1 (ships with Windows) and Docker Desktop.
Nothing to install, no runtime and no packages: the panel is a PowerShell
`HttpListener` serving static HTML, and a `localhost` prefix binds without
administrator rights.

What it does:

- **Status** of each `rs<year>` container, whether its image is built, and
  whether the admin page actually answers yet (a running Windows container is
  not the same as a started IIS).
- **Start / stop / restart / rebuild / remove** per version, plus the proxy;
  "start all" and "stop all" for everything at once.
- **Live docker output** for every operation, with a job history. Builds take
  20–45 minutes and keep running if the panel is closed and reopened.
- **Settings** — host port and models folder per version, which versions the
  proxy routes, proxy port, docker contexts, panel port.
- **Docker Desktop / Windows engine** state, with buttons to start Docker
  Desktop and switch the daemon to Windows containers.

The panel writes its settings to `panel/runtime/panel.config.json` and generates
the compose files and `nginx.conf` it runs into `panel/runtime/compose/`. That
directory is gitignored, so the samples under `samples/` stay untouched. Every
compose call passes `-p samples`, which keeps the existing image names
(`samples-rs<year>`) and container names (`rs<year>`) — so switching to the
panel never triggers a rebuild of an image you already have.

The panel UI is in Russian.

### Security

The listener is bound to `localhost` only, and every API call must carry a
session token that is generated at start and injected into the page when it is
served. A page on another origin can neither read that token nor drive docker
through the panel. Do not expose the panel port beyond this machine — it runs
docker commands.

## Usage without the panel

```
docker-compose -f .\docker-compose.<version>.yml up
```

### Launch

Open browser with link:
```
http://localhost/revitserveradmin<version>
```
