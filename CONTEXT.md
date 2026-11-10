# jupiter-os

The Jupiter home/lab infrastructure: a declarative, ZFS-backed NixOS fleet.
This glossary covers the fleet's domain language — hosts, the platform being
built, and the arcade pipeline.

## Language

### Platform

**Unified platform**:
The single Go server-rendered web application on callisto that absorbs all user-facing apps as registered modules. Modular core: layout, navigation, ZEUS tokens, access.
_Avoid_: portal, dashboard app, website

**Module** (platform module):
An app registered into the unified platform at a URL prefix (`/arcade`, `/suno`, `/home`), owning its handlers, templates, and Postgres schema.
_Avoid_: app (for platform modules), plugin

**Core**:
The platform minus its modules: layout shell, navigation, ZEUS token serving, module registry, deployment.
_Avoid_: framework, base app

**Module registry**:
The compile-time mechanism by which a module declares itself to the core and receives its URL prefix.
_Avoid_: app store, marketplace

**HA absorb**:
The strategy of consuming Home Assistant's REST/WebSocket API as a data source and rendering ZEUS views over it, until HA runs headless (a service, not a surface).
_Avoid_: HA integration (vague), Lovelace replacement

### Hosts and topology

**Kiosk**:
A thin web client host — fullscreen browser pointed at the unified platform. Gaming mode (Pegasus/QML) exists on kiosks for gaming only.
_Avoid_: terminal, dashboard host

**Serving host**:
callisto, the host from which every user-facing service is served: the unified platform, Postgres, MQTT, delegated builds.
_Avoid_: app server (ambiguous with the platform itself)

**NAS**:
europa, storage-only: NFS, PXE binaries, Harmonia. No new services land on it except fileserver apps by definition.
_Avoid_: file server (that's europa's role, not a generic term)

### Arcade pipeline

**Arcade webapp**:
The existing in-tree Go service (`modules/services/arcade-webapp.nix`, `pkgs/arcade-webapp/`) being absorbed as the platform's first module. It runs the ROM pipeline: DAT currency, aria2 downloads, igir verify, Skyscraper scraping, launcher-DB generation, curation.
_Avoid_: arcade module (that's the post-absorption thing), RomM

**ROM pipeline**:
The multi-stage pipeline the arcade webapp drives (acquire → verify → scrape → launcher-DB → inventory). Runs on europa through the webapp.
_Avid_: 
_Avoid_: ROM downloader, scraper

### Data

**Postgres rule** (stack-guide §5):
Postgres on callisto is canonical for app state; files are artifacts, and where a file and its row disagree, the row wins.
_Avoid_: "SQLite anywhere", file-based truth

**Activation-time secrets**:
sops+age secrets read at NixOS activation, never at build time, so `nix flake check` works without keys.
_Avoid_: build-time secrets, plaintext fallback

## Out of vocabulary scope

General NixOS/Nix concepts (modules, options, flakes), general web concepts (templates, CSS custom properties) — see `CLAUDE.md` and `docs/stack-guide.md`.
