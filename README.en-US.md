# MTProxy Management Script

One-command deployment and management for MTProxy with two kernels: Go ([mtg](https://github.com/9seconds/mtg)) and Rust ([Telemt](https://github.com/telemt/telemt)). Supports Debian, Ubuntu, CentOS / RHEL / Rocky / Alma and Alpine Linux on amd64 and arm64.

[中文](README.md)

## Install

```bash
bash <(curl -fsSL https://mtproxy.813099.xyz)
```

Then run `mtp` to open the menu. The interface is in Chinese; every feature is also available as a command (see below).

Install the development channel (`main` branch):

```bash
MTP_CHANNEL=dev bash <(curl -fsSL https://mtproxy.813099.xyz)
```

## Features

**Kernels**

- **Go (mtg)**: low memory footprint, suited to personal use or small groups.
- **Telemt (Rust)**: multiple users. Each user can have a dedicated port, a traffic quota, an expiry date and upload/download speed limits.
- Both kernels can run at the same time. IPv4, IPv6 and dual-stack are supported.
- Binaries are downloaded from GitHub Releases and verified with SHA-256.
- Updating a kernel replaces only the binary, so configuration and links stay the same. If the new binary fails to start, the previous one is restored automatically.

**User management (Telemt)**

- A table view shows traffic progress and expiry dates. It highlights users at 80 % of their quota or within 7 days of expiry.
- Quotas accept units: `50G`, `500M`, `1.5T`.
- Expiry dates accept `2026-12-31`, `2026-12-31 18:00` or `+30d`. `+30d` extends from the current expiry date.
- Traffic can be reset monthly or once on a chosen date. Expired users are skipped. A reset day beyond the length of the month runs on the last day of that month.
- Each user has their own link, QR code and secret rotation.

**Reliability and security**

- User data lives in `users.db`. The full Telemt configuration is regenerated on every change, and a failed restart rolls back to the previous state.
- Telemt is stopped before its usage file is modified, so the kernel's shutdown flush cannot overwrite a reset.
- The mtg secret is stored in a mode-600 config file instead of the process arguments.
- systemd units are sandboxed by default, and mtg runs as an unprivileged user. The script falls back to a compatible unit when the host does not support sandboxing.
- Secrets are hidden when logs are shown. OpenRC logs are rotated weekly.

**Operations**

- `doctor` checks:
  - services and listening ports
  - public reachability
  - firewall rules
  - clock skew
  - TLS 1.3 support of the masking domain
  - BBR
  - available updates

  It can open firewall ports and enable BBR for you.
- `backup` / `restore` package configuration, users and traffic usage into a single file for migration.
- A custom link host (domain or IP) can be set for NAT machines.
- Telemt supports a promoted channel (ad_tag).

## Command line

```bash
mtp status | info | start | stop | restart [go|telemt]
mtp logs [go|telemt] [-f]
mtp user list [--json]
mtp user add alice --quota 50G --expire +30d --port 8443 --up 2 --down 10
mtp user edit alice --expire +30d --no-limit
mtp user link alice --qr
mtp user reset alice
mtp user del alice -y
mtp reset-now
mtp doctor [--fix]
mtp upgrade-core [go|telemt]
mtp update [--dev|--stable]
mtp backup [file] | mtp restore file
mtp uninstall
```

Run `mtp help` for details.

## File layout

| Path | Contents |
|---|---|
| `/etc/mtproxy/` | Configuration and user data |
| `/etc/mtproxy/telemt.extra.toml` | Optional custom Telemt tables, appended to the generated config |
| `/etc/telemt_quota.json` | Telemt traffic usage (path fixed by the kernel) |
| `/var/lib/mtproxy/` | State and backups |
| `/var/log/mtproxy/` | Logs |
| `/opt/mtproxy/bin/` | Kernel binaries |

## Upgrading from 2.x

Run `mtp update`. On first start the new version migrates the old configuration automatically:

- Users, quotas, expiry dates, speed limits, dedicated ports, traffic usage and the reset schedule are all kept.
- Existing links keep working.
- The old files are archived in `/var/lib/mtproxy/backups/legacy-*.tar.gz`.
- Services restart once during migration.
- If migration fails, the services keep running on the old configuration. Run `mtp migrate` to retry.

## Development

The script is split into modules under `src/`. The single-file `mtp.sh` is generated:

```bash
bash scripts/build.sh        # writes mtp.sh and mtp.sh.sha256
npm test                     # worker tests + shell unit tests
bash tests/shell/cores.sh    # starts the real kernels with generated configs (needs network)
```

Pushing a `v3.x.y` tag moves the `stable` branch to that tag. The install endpoint serves `stable`, and falls back to `main` if `stable` does not exist.

---

For personal learning and testing only.
