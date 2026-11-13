.. raw:: html

   <p align="right">
     <picture>
       <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/belikh/design/latest/packages/graphics/logo/jupiter-logo-dark.svg">
       <img alt="jupiter.au" src="https://raw.githubusercontent.com/belikh/design/latest/packages/graphics/logo/jupiter-logo-light.svg" width="260">
     </picture>
   </p>

   <h1>jupiterOS</h1>

.. meta::
   :description: Declarative NixOS monorepo for the jupiter.au house network: seven hosts on ZFS, each described in this repository.

A declarative NixOS monorepo for the jupiter.au house network: seven hosts on ZFS, each described in this repository and built from it. Hosts are named after moons of Jupiter. If something is not in this repository, it is not part of the system.

`Hosts`_ · `How it fits together`_ · `Rules`_ · `Repository layout`_ · `Develop`_ · `Deploy`_ · `Further reading`_

|

.. raw:: html

   <p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/rule/end-dark.svg"><img alt="" src="https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/rule/end-light.svg" width="50%"></picture></p>


|

Hosts
-----

Each kiosk runs a fullscreen browser pointed at the platform served from callisto. The display renders and callisto computes.

.. list-table::
   :header-rows: 1

   * - Host
     - Location
     - Role
   * - |monitor-l| |monitor-d| ``amalthea``
     - bedroom
     - Kiosk. The template the other kiosks are cut from.
   * - |monitor-l| |monitor-d| ``metis``
     - kitchen
     - Kiosk.
   * - |monitor-l| |monitor-d| ``thebe``
     - robbie-room
     - Kiosk.
   * - |monitor-l| |monitor-d| ``adrastea``
     - office
     - Kiosk. Registered and passing CI; waiting for its disk.
   * - |disk-l| |disk-d| ``europa``
     - ``10.1.1.2``
     - ZFS NAS, NFS shares, netboot binaries and the Harmonia binary cache.
   * - |server-l| |server-d| ``callisto``
     - ``10.1.1.3``
     - Serving host: fleet Postgres, MQTT broker and the shared builder.
   * - |cloud-l| |cloud-d| ``pallene``
     - cloud
     - Builder on a Kamatera VPS, not part of the fleet. Disk-booted from ``.#pallene-raw``.

``ganymede`` (a resolver) and ``himalia`` (a laptop) are reserved names.

europa serves only files: NFS shares, static netboot binaries, and Harmonia, which serves the Nix store read-only on port 5000.

callisto runs the unified platform: the arcade, the Suno archive, the house assistant and every view the kiosks show. The MQTT broker carries house events and Postgres (port 5432) stores what must persist.

Current host state, verification dates and known stale items are in `CLAUDE.md <CLAUDE.md>`__.

|

How it fits together
--------------------

- **Events.** Kiosk agents and the house assistant publish to Mosquitto on callisto.
- **Builds.** GitHub Actions builds each host's closure on free runners and pushes it over the tailnet to Harmonia on europa. Only ``main`` is pushed, and the last three generations per host are kept as GC roots.
- **Netboot.** europa's closure carries only static iPXE and TFTP. The boot assets are derived from callisto and published after callisto has switched to the generation they were built from, so building europa never builds callisto.
- **Secrets.** sops and age, one key per host. Secrets are read at activation, never at build time, so ``nix build`` and CI run without the keys.
- **Games.** europa runs the cartridge pipeline (DAT checks, aria2 fetch, igir verify, scrape to Pegasus metadata) behind the arcade webapp. The kiosks no longer run games; their gaming stack was removed on 2026-11-10.

|

Rules
-----

1. **Stock kernel on ZFS.** ZFS hosts run the stock ``linuxPackages``, the kernel the cache already builds.
2. **No input without a user.** A flake input needs a registered host that uses it.
3. **No wiring before both ends.** Cross-host wiring waits until both hosts are registered and building.
4. **No global overlays on** ``stdenv``. One overlay setting ``doCheck = false`` changed the output hash of everything downstream, missed cache.nixos.org, and made europa run 2244 local builds instead of 70. Override the one package that misbehaves.
5. **Everything substitutes.** Every registered host must build from cache.nixos.org plus our own cache. ``nix flake check`` is eval-only, and every registered host must pass it.
6. **Shared behaviour lives in modules.** Cross-host configuration goes in ``modules/<category>/`` behind ``jupiter.*`` options. Hosts turn options on and do not inline configuration.

|

Repository layout
-----------------

.. code-block:: text

   flake.nix      entry point; every registered host is also a flake check
   hosts/         one directory per host (configuration.nix)
   modules/       NixOS modules behind jupiter.* options
                  (boot/ core/ desktop/ network/ services/ storage/);
                  common.nix is the base layer
   pkgs/          flake packages (arcade-webapp, ariang, nom-web, suno-backup, ...)
   docs/          style guide (ZEUS), stack guide, runbooks, ADRs
   secrets/       sops + age, one recipient key per host

|

Develop
-------

.. code-block:: sh

   make check              # evaluate every registered host (nix flake check --no-build)
   make build-all          # build the kiosk closures
   make test-<host>        # build and boot a host in a QEMU VM
   make boot-smoke-<host>  # headless CI-style boot test
   make fmt                # format with nixfmt-rfc-style; make fmt-check to verify

|

Deploy
------

A host deploys itself from the pushed flake. Commit and push first, then run this on the host:

.. code-block:: sh

   ssh root@<host> -- nixos-rebuild switch --flake github:belikh/jupiter-os#<host>

Hosts without custom builds substitute their whole closure. Hosts with custom builds are built on the builders, pushed to Harmonia and substituted from there. After a deploy, check the result: read the changed file or watch the service restart.

|

Further reading
---------------

- `CLAUDE.md <CLAUDE.md>`__: infrastructure conventions, host status, deploy rules.
- `docs/style-guide.md <docs/style-guide.md>`__: ZEUS, the design language used by every kiosk surface.
- `docs/stack-guide.md <docs/stack-guide.md>`__: which language is used for what, where services run, and the banned list.

|

.. raw:: html

   <p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/rule/end-dark.svg"><img alt="" src="https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/rule/end-light.svg" width="50%"></picture></p>


|

.. raw:: html

   <p align="right"><sub>jupiter.au</sub></p>

.. |monitor-l| image:: https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/icon/monitor-light.svg#gh-light-mode-only
   :width: 20
   :alt:
.. |monitor-d| image:: https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/icon/monitor-dark.svg#gh-dark-mode-only
   :width: 20
   :alt:
.. |disk-l| image:: https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/icon/disk-light.svg#gh-light-mode-only
   :width: 20
   :alt:
.. |disk-d| image:: https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/icon/disk-dark.svg#gh-dark-mode-only
   :width: 20
   :alt:
.. |server-l| image:: https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/icon/server-light.svg#gh-light-mode-only
   :width: 20
   :alt:
.. |server-d| image:: https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/icon/server-dark.svg#gh-dark-mode-only
   :width: 20
   :alt:
.. |cloud-l| image:: https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/icon/cloud-light.svg#gh-light-mode-only
   :width: 20
   :alt:
.. |cloud-d| image:: https://raw.githubusercontent.com/belikh/design/latest/packages/github/graphics/icon/cloud-dark.svg#gh-dark-mode-only
   :width: 20
   :alt:
