# Networking & DNS

## 1. Subnets / VLANs

Defined declaratively in `terraform/unifi/default.nix` (applied to the UDM
Pro) and must be kept in sync with `jupiter.dns.allowedNetworks` in
`hosts/lenovo/configuration.nix` — see the cross-reference comments in both
files (and in `CLAUDE.md`).

| Network | VLAN | Subnet | DHCP range | DNS server |
|---|---|---|---|---|
| Default LAN | (untagged) | `10.1.1.0/24` | `10.1.1.6` – `10.1.1.254` | `10.1.1.20` |
| Cameras | 2 | `192.168.3.0/24` | `192.168.3.6` – `192.168.3.254` | `10.1.1.20` |
| IOT | 3 | `192.168.2.0/24` | `192.168.2.6` – `192.168.2.254` | `10.1.1.20` |
| headscale mesh | — | `100.64.0.0/10` (+ `fd7a:115c:a1e0::/48` v6) | (mesh-assigned) | `10.1.1.20` |

Static addresses (DHCP pools start at `.6`, leaving `.2`–`.5` for static
hosts):

| Host | Address | Interface |
|---|---|---|
| Gateway (UDM Pro) | `10.1.1.1` | — |
| `nas` | `10.1.1.2` | `enp2s0f0` (bond0 once LACP is enabled) |
| `lenovo` | `10.1.1.20` | `br0` (member: `enp1s0`) |
| Home Assistant VM | `10.1.1.72` | (libvirt bridge, on `lenovo`) |
| smokeping | `10.1.1.221` | (referenced in DNS records; no corresponding host in this repo) |

## 2. Internal DNS resolver (`lenovo`, `jupiter.dns`)

`lenovo` is the only authoritative/recursive resolver for the fleet. Every
other host's `networking.nameservers` defaults to `10.1.1.20`
(`modules/common.nix`); `lenovo` points at itself (`127.0.0.1`).

Two layered services, both declared in `modules/services/dns.nix`:

```
                LAN / VLANs / headscale mesh
                          │
                          ▼
                 ┌──────────────────┐
                 │ unbound (port 53)│  authoritative for home.jupiter.au
                 │  - DNSSEC valid. │  (local-zone/local-data from
                 │  - aggressive    │   jupiter.dns.records)
                 │    caching       │
                 └────────┬─────────┘
                          │ forward-zone "." → 127.0.0.1:5353
                          ▼
                 ┌──────────────────┐
                 │ dnscrypt-proxy   │  anonymized + encrypted
                 │  (port 5353)     │  upstream-only; ignore_system_dns
                 └──────────────────┘
                          │
                          ▼
                 Internet (anonymized relay ≠ resolver operator)
```

**Why this shape:** unbound is a *pure forwarder* for anything outside the
internal zone — it never recurses to the public root in cleartext, so the
ISP can't see query content even on a leak. dnscrypt-proxy's anonymized
routing additionally splits "who you are" from "what you asked": the relay
sees the client IP but not the query, the resolver sees the query but not
the client IP.

**Internal zone records** (`jupiter.dns.records`, `home.jupiter.au`):

| FQDN | IP |
|---|---|
| `gateway.home.jupiter.au` | `10.1.1.1` |
| `nas.home.jupiter.au` | `10.1.1.2` |
| `lenovo.home.jupiter.au` | `10.1.1.20` |
| `ha.home.jupiter.au` | `10.1.1.72` |
| `smokeping.home.jupiter.au` | `10.1.1.221` |

`jupiter.dns.allowedNetworks` (who may query the resolver): loopback, the
default LAN, IOT VLAN, Cameras VLAN, and the headscale mesh range — i.e.
every network in the table above.

**UniFi firewall enforcement** (`terraform/unifi/default.nix`): a rule set
that only allows the resolver host (`10.1.1.20`) out on ports 53/853, and
drops every other LAN→WAN DNS attempt — so a device can't bypass the
internal resolver even if misconfigured.

## 3. Mesh VPN (headscale)

`modules/headscale.nix` runs a self-hosted, Tailscale-protocol-compatible
control plane (`services.headscale`) on `lenovo`, exposed publicly at
`https://headscale.jupiter.au` via the Cloudflare Tunnel (not directly
port-forwarded). MagicDNS is on, base domain `jupiter.mesh`; mesh clients are
told to use `10.1.1.20` for DNS too, so their queries get anonymized through
home and they can resolve internal `home.jupiter.au` names while roaming.

`lenovo` is the only host running headscale — it's the single control plane
for the fleet.

## 4. Public ingress (Cloudflare Tunnel)

`modules/cloudflared.nix` runs a single `cloudflared` tunnel on `lenovo`
(credentials: sops secret `cloudflare_cert`), the *only* path from the public
internet into the fleet — no inbound ports are forwarded at the edge.

| Public hostname | Backend |
|---|---|
| `headscale.jupiter.au` | `http://127.0.0.1:8080` (headscale) |
| `n8n.jupiter.au` | `http://127.0.0.1:5678` (n8n) |
| `ha.jupiter.au` | `http://127.0.0.1:8123` (Home Assistant VM) |
| anything else | `http_status:404` |

DNS for `jupiter.au` itself is managed via the `terraform/cloudflare` stack —
see [10-terraform.md](10-terraform.md).

## 5. iSCSI / NFS / SMB data-plane traffic

Storage protocols (iSCSI to `elitedesk`, NFS to LAN/mesh clients, SMB to LAN
clients) run over the same `10.1.1.0/24` network as everything else — no
dedicated storage VLAN exists today. See
[06-storage-and-backups.md](06-storage-and-backups.md) for exports/shares
and firewall ports.

## 6. Firewall ports opened per host (NixOS `networking.firewall`)

| Host | Ports | Why |
|---|---|---|
| `lenovo` | TCP/UDP 53 (dns.nix), TCP 8080 (headscale.nix) | Resolver + mesh control plane |
| `nas` | TCP 2049 (nas-nfs.nix), TCP 3260 (iscsi.nix), Samba ports (zfs-nas.nix, `openFirewall`), TCP 8384/22000 + UDP 22000/21027 (syncthing.nix) | NFS, iSCSI, SMB, Syncthing |
| `t460s` | TCP 8384/22000, UDP 22000/21027 (syncthing.nix) | Syncthing |
| `elitedesk` | none opened in-repo | Diskless netboot node |
