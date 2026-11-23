# Host configuration

A host is a directory under `hosts/<category>/<name>/` containing
`configuration.nix`. `flake.nix` derives `nixosConfigurations` from those
directories. There is no installer script in this repository.

## Define a host

1. Create `hosts/<category>/<name>/configuration.nix`.
2. Import the shared modules the host needs from `modules/`.
3. Set options under `paxos.*`. Cross-host addresses and ports come from
   `modules/runtime/endpoints.nix`.

## Evaluate and build

```bash
nix eval .#nixosConfigurations --apply 'c: builtins.attrNames c'
nix eval --raw .#nixosConfigurations.<name>.config.networking.hostName
nix build .#nixosConfigurations.<name>.config.system.build.toplevel --no-link
```

Evaluation happens one host per process. This keeps peak memory bounded and
lets one failing host be reported without hiding the others.

## Verify a change

```bash
make all
bash -n scripts/*.sh
nix-instantiate --parse hosts/<category>/<name>/configuration.nix
```
