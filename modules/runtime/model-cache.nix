{ pkgs }: {
  mkDirStage =
    name:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.rsync
      ];
      text = ''
          src="''${1:?src}"; dest="''${2:?dest}"; maxbytes="''${3:?maxbytes}"
          total=$(du -sb "$src" | cut -f1)
        if [ "$total" -gt "$maxbytes" ]; then
          echo "model $total B exceeds cache cap $maxbytes B; serving from $src" >&2
          echo "$src"
          exit 0
        fi
        mkdir -p "$dest"
        name=$(basename "$src")
        if [ -d "$src" ]; then
          if [ -d "$dest/$name" ] && [ "$(du -sb "$dest/$name" | cut -f1)" = "$total" ]; then

            chmod -R a+rX "$dest/$name" 2>/dev/null || true
            touch "$dest/$name"
            echo "$dest/$name"
            exit 0
          fi

          rsync -a --delete \
            --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r \
            "$src"/ "$dest/$name"/
          echo "$dest/$name"
          exit 0
        fi

        if [ -e "$dest/$name" ] && [ ! -f "$dest/$name" ]; then
          rm -rf "''${dest:?}/''${name:?}"
        fi
        if [ -f "$dest/$name" ] && [ "$(du -sb "$dest/$name" | cut -f1)" = "$total" ]; then

          chmod a+r "$dest/$name" 2>/dev/null || true
          touch "$dest/$name"
          echo "$dest/$name"
          exit 0
        fi
        rsync -a --chmod=Fu=rw,Fg=r,Fo=r "$src" "$dest/$name"
        echo "$dest/$name"
      '';
    };
}
