# Host examples

The tree under `hosts/` contains examples only. Every address, domain, and key is
a documentation placeholder. No host holds real network data, credentials, or
container metadata.

## Categories

| Category | Path | Purpose |
|----------|------|---------|
| metal | `hosts/metal/` | build and bastion hosts |
| infra | `hosts/infra/` | infrastructure guests |
| apps | `hosts/apps/` | application guests |

## Nodes

| Node | Category | Role | Application set |
|------|----------|------|-----------------|
| dev | metal | builds and signs closures | none |
| bsn | metal | SSH entry point and deploy origin | none |
| git | infra | git forge | `forgejo` |
| r1 | infra | runner | `modules/platform/runners.nix` |
| r2 | infra | runner | `modules/platform/runners.nix` |
| metrics | infra | monitoring | none |
| cache | infra | binary cache | `nixcache` |
| artifacts | infra | artifact store | `nixcache` |
| infer-01 | infra | inference | role example |
| gateway-01 | infra | gateway | role example |
| app-01 | apps | application guest | none |
| app-portal | apps | authentication portal | `authelia` |
| app-ide | apps | browser IDE | `code-server` |
| game-01 | apps | game services | role example |

Role examples show the node declaration and handoff without a workload module.
The modules for the original inference, gateway, and game workloads are not part
of this release.

## Application sets

| Module | Purpose |
|--------|---------|
| `modules/workloads/authelia.nix` | authentication portal |
| `modules/workloads/forgejo.nix` | git forge |
| `modules/workloads/code-server.nix` | browser IDE |
| `modules/workloads/nixcache.nix` | binary cache |

Enabling one is an option assignment in a host file. The workload module lives
under `modules/workloads/`; secrets are supplied at runtime and are not part of
the repository.

## Inference node example

```nix
(import ../../../modules/platform/guest.nix {
  specId = "infer-01";
  inherit (site) domain;
  address = "198.51.100.30";
  vlan = 3010;
  cores = 16;
  memory = 65536;
  diskGiB = 200;
  imageSize = "32G";
  firewall.tcp = [
    80
    443
  ];
  wazuhAgent = false;
})
```

All values are placeholders. The VM ID is derived from VLAN 3010 and the last
address octet.

## Handoff

Each node is a directory with a `configuration.nix`. That file imports shared
modules from `modules/` and sets options under `paxos.*`. Three shared data
files feed the examples:

| File | Contents |
|------|----------|
| `modules/runtime/endpoints.nix` | addresses and service ports |
| `modules/runtime/rings.nix` | edge and core node lists |
| `modules/runtime/ids.nix` | per-stack user and UID mappings |

Metal hosts import `modules/platform/base.nix` and the disk layout at
`hosts/metal/disk-config.nix`. Guests import `modules/platform/guest.nix`, which
derives the VM ID from the VLAN and the last address octet and asserts that the
address matches the VLAN.

## Pipeline

1. Options are set in a host `configuration.nix`.
2. Shared modules consume `paxos.*`; `endpoints.nix`, `rings.nix`, and `ids.nix`
   supply cross-host data.
3. `nix eval .#nixosConfigurations.<node>.config.system.build.toplevel.drvPath`
   evaluates the host.
4. A release signature authorizes a generation switch, checked by
   `modules/platform/ops.nix`.
5. `make all` runs repository checks and unit tests.
