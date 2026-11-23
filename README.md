# pxth pxOS Platform

NixOS hosts configured as a fleet from shared modules, with role-separated nodes, ephemeral roots, and signed release switches.

## Layout

| Path | Contents |
|------|----------|
| `flake.nix`, `flake.lock` | flake outputs and pinned inputs |
| `hosts/` | host configurations |
| `modules/` | NixOS modules |
| `scripts/` | operational helpers and CI bots |
| `tests/fleet/` | checks for the helpers |
| `docs/`, `examples/` | documentation and placeholder secrets |

## Hosts

Hosts are grouped into `metal`, `infra`, and `apps`. The example nodes are
`dev`, `bsn`, `git`, `r1`, `r2`, `metrics`, `cache`, `artifacts`, `infer-01`,
`gateway-01`, `app-01`, `app-portal`, `app-ide`, and `game-01`; their application
sets and the module handoff are described in [docs/hosts.md](docs/hosts.md). A
directory under `hosts/` containing `configuration.nix` becomes a
`nixosConfiguration`. Options use the `paxos.*` namespace.

## Architecture

Hosts are separated by role. Each role holds different credentials and trusts a different set of hosts.

| Role | Host | Holds | Responsibility |
|------|------|-------|----------------|
| dev | build host | release signing key | builds and signs closures; holds no deploy key |
| bsn | metal host | SSH user CA, ops deploy key | only SSH entry point and deploy origin |
| infra | guests | per-host age identity | runs workloads; holds no signing or deploy key |

The separation is enforced in the configuration:

- SSH: password login and root login are off. Only the `operator` account is allowed in, with per-host source-restricted keys. No fleet-wide key exists.
- Secrets: each host has its own age identity. Shared secrets list their recipients. The repository key is for recovery and is not planted on hosts.
- Deploys: `paxos-ops-switch` refuses a generation without a valid signature. The signing key stays on dev; only the signature travels with the closure.
- Rings: `modules/runtime/rings.nix` divides hosts into edge and core. Core hosts are listed explicitly.
- Hosts: the root filesystem is ephemeral. Durable state lives under `/persist`, and the split is defined in `modules/core/ephemeral.nix`.
- Workloads: containers run rootless with the sandbox settings in `modules/runtime/service-harden.nix`.

## Commands

```sh
nix eval .#nixosConfigurations --apply 'c: builtins.attrNames c'
nix build .#nixosConfigurations.bsn.config.system.build.toplevel --no-link
make all
```

## Secrets

No keys, tokens, or encrypted values are in this repository. Runtime secrets
come from outside it.

License: MIT.

## Provisioning flow

`node config → eval → build → sign → switch → host`

| Stage | Reads | Produces |
|-------|-------|----------|
| Host definition | `configuration.nix`, `endpoints.nix`, `rings.nix`, `ids.nix` | host options |
| Eval | host options | evaluated configuration |
| Build | evaluated configuration | store closure |
| Sign | store path and revision | signature; key held outside the repository |
| Switch | closure and signature | verified generation, or rejection with a log entry |
| Apply | generation | running host |
