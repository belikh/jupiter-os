# jupiterOS

> *"The network is the computer."*

A house has many rooms. It has one computer.

The machines of this house are named for the moons of Jupiter:
amalthea, metis, thebe, adrastea, europa, callisto. Jupiter itself is
weather — enormous, banded, all storm, nowhere to stand. The moons are
ground. That is the naming discipline: the fashion of the season is
weather; wire, disk, cache and configuration under version control are
ground. We build on ground.

**jupiterOS** is the description of that one computer: a declarative,
ZFS-backed NixOS monorepo. A moon is a description in this repository
before it is a machine, and remains a description after the hardware
is gone. Press a switch and a moon becomes what it was described to be
— substituting from the caches, reading its secrets as it comes alive,
needing nothing that is not written here. If it is not in this
repository, it is not true.

## One computer, moon by moon

A kiosk is not a computer. It is a window. Each kiosk runs a
fullscreen browser pointed at the platform served from callisto; the
display renders, the network computes. Behind the wall, the standing
work has a place to happen:

| Moon | Station | Post |
|---|---|---|
| `amalthea` | bedroom | kiosk — the template the other kiosks are cut from |
| `metis` | kitchen | kiosk |
| `thebe` | robbie-room | kiosk |
| `adrastea` | office | kiosk — registered, CI-green, awaiting its disk |
| `europa` | `10.1.1.2` | the disk — ZFS NAS, NFS, netboot binaries, the Harmonia cache |
| `callisto` | `10.1.1.3` | the processor — serving host: fleet Postgres, MQTT broker, shared builder |
| `pallene` | cloud | a builder (Kamatera VPS), not fleet; disk-booted from `.#pallene-raw` |

`ganymede` and `himalia` are names held in reserve — a resolver, a
laptop — when their time comes.

**europa holds.** The disk, and little else: NFS shares, the netboot's
static binaries, and Harmonia serving the store read-only on `:5000`.
A fileserver on a disk is permanent by definition, not an exception to
its station.

**callisto serves.** The unified platform — the arcade, the Suno
archive, the house assistant, every view the windows show — runs on
callisto, beside the fleet Postgres (`:5432`) and the MQTT broker that
carries the house's events. MQTT is the nervous system. Postgres is
the ledger. What must persist is written; everything else is current.

Live state, verification dates and staleness caveats live in
[`CLAUDE.md`](CLAUDE.md). Believe measurement, not memory.

## The wire

- **Events → callisto.** Kiosk agents and the house assistant publish
  to mosquitto; the bus is the house's common tongue.
- **Builds → CI, then the cache.** GitHub Actions builds each moon's
  closure on free runners and pushes it over the tailnet to Harmonia
  on europa — `main` only, the last three generations per host pinned
  as roots. The builders are not in the house. The memory is.
- **Netboot → europa.** europa's closure carries only static
  iPXE/TFTP; the boot assets derive from callisto and are published
  only after callisto has switched to the generation they were cut
  from — so building europa never builds callisto.
- **Secrets → sops + age.** One key per moon, read at activation and
  never at build. `nix build` and CI run without the keys. A machine
  is entrusted with its secrets only in the moment it becomes itself.
- **Play → a service.** europa runs the cartridge pipeline (DAT
  currency, aria2 fetch, igir verify, scrape to Pegasus metadata)
  behind the arcade webapp; the kiosks mount the results read-only and
  flip into gaming mode to play them. Play is scheduled, cached and
  verified like any other service. Why should it not be.

## Doctrine

Held to be true, and learned the expensive way:

1. **Stock kernel on ZFS.** ZFS moons run the stock `linuxPackages` —
   the kernel the cache has always built. Custom kernels are weather.
2. **No input without a user.** A flake input is justified only by a
   registered host that uses it.
3. **No wire before both ends.** Cross-host wiring waits until both
   hosts are registered and building.
4. **Never perturb the world.** No global overlay may rewrite
   `stdenv`. One such overlay — a harmless-looking `doCheck = false` —
   changed the output hash of everything downstream, matched nothing
   in cache.nixos.org, and cost europa 2244 local builds where 70 was
   correct. Measured, with the overlay as the only variable. Override
   the one package that misbehaves. Never the world.
5. **Everything substitutes.** A moon that cannot be built from
   cache.nixos.org is not a moon; it is a hobby. `nix flake check` is
   eval-only, and every registered host must stay green.
6. **Description is destiny.** Cross-host behaviour lives in
   `modules/<category>/` behind `jupiter.*` toggles; hosts opt in,
   nobody inlines config. The repository is the only place a machine
   is allowed to come from.

## The repository

```
flake.nix      entry point; every registered host is also a flake check
hosts/         one directory per moon (configuration.nix)
modules/       reusable NixOS modules behind jupiter.* options
               (boot/ core/ desktop/ gaming/ network/ services/
               storage/); common.nix is the base layer
pkgs/          flake packages: ariang, dsh, nom-web, suno-backup,
               arcade-webapp
docs/          style-guide (ZEUS), stack-guide, runbooks
secrets/       sops + age; one recipient key per moon
```

## Working on it

```bash
make check              # evaluate every registered host (nix flake check --no-build)
make build-all          # build the kiosk closures
make test-<host>        # build & boot a moon in a QEMU VM
make boot-smoke-<host>  # headless CI-style boot test
make fmt                # nixfmt-rfc-style; make fmt-check to verify
```

Deploying is pulling, not pushing. A moon deploys itself from the
pushed flake: commit and push first, then, on the moon itself —

```bash
ssh root@<host> -- nixos-rebuild switch --flake github:belikh/jupiter-os#<host>
```

Untuned moons substitute their whole closure. Tuned ones build on the
builders, land in Harmonia, and substitute from there. Afterwards,
verify by observation — read the changed file, watch the service
restart — never by assertion.

## Authority

- [`CLAUDE.md`](CLAUDE.md) — infrastructure conventions, host status,
  deploy discipline.
- [`docs/style-guide.md`](docs/style-guide.md) — ZEUS, the design
  language. The house speaks with one face; every surface a window
  shows is ZEUS.
- [`docs/stack-guide.md`](docs/stack-guide.md) — what may be written
  in what, where services run, and the banned list.

