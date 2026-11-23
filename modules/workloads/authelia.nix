
{
  config,
  lib,
  ...
}:
let
  cfg = config.paxos.authelia;
  eyd = config.paxos.ephemeral.enable;

  factorName =
    if cfg.cookies == [ ] then
      "Authelia"
    else
      lib.removePrefix "https://" (builtins.head cfg.cookies).authelia_url;
  user = "authelia";
  state = "/var/lib/${user}";
  persist = "/persist${state}";
  cookie = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "authelia_session";
      };
      domain = lib.mkOption { type = lib.types.str; };
      authelia_url = lib.mkOption { type = lib.types.str; };
      default_redirection_url = lib.mkOption { type = lib.types.str; };
      expiration = lib.mkOption {
        type = lib.types.str;
        default = "12h";
      };
      inactivity = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };
      remember_me = lib.mkOption {
        type = lib.types.str;
        default = "1M";
      };
      same_site = lib.mkOption {
        type = lib.types.str;
        default = "lax";
      };
    };
  };
  rule = lib.types.submodule {
    options = {
      domain = lib.mkOption { type = lib.types.listOf lib.types.str; };
      policy = lib.mkOption { type = lib.types.str; };

      subject = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };
in
{
  options.paxos.authelia = {
    enable = lib.mkEnableOption "Authelia file-backend portal";

    usersFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Age-encrypted Authelia users database.";
    };

    jwtSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };

    storageKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };

    sessionSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };

    cookies = lib.mkOption {
      type = lib.types.listOf cookie;
      default = [ ];
    };

    accessRules = lib.mkOption {
      type = lib.types.listOf rule;
      default = [ ];
    };

    oidcHmacSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };

    oidcIssuerPrivateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };

    oidcClients = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options.client_id = lib.mkOption {
            type = lib.types.str;
            description = "Authelia client_id.";
          };
        }
      );
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    paxos.cover.resticHold = [ "authelia.service" ];
    paxos.cover.resticPaths = [ persist ];

    assertions = [
      {
        assertion =
          cfg.usersFile != null
          && cfg.jwtSecretFile != null
          && cfg.storageKeyFile != null
          && cfg.sessionSecretFile != null
          && cfg.cookies != [ ]
          && cfg.accessRules != [ ];
        message = "paxos.authelia needs users, jwt, storage key, session secret, cookies, and access rules";
      }
      {
        assertion =
          (cfg.oidcHmacSecretFile == null) == (cfg.oidcIssuerPrivateKeyFile == null)
          && (cfg.oidcHmacSecretFile == null) == (cfg.oidcClients == [ ]);
        message = "paxos.authelia OIDC needs the HMAC secret, the issuer key, and at least one client";
      }
    ];

    paxos.ephemeral.binds = lib.mkIf eyd [
      {
        path = state;
        store = persist;
        mode = "0700";
        inherit user;
        group = user;
        parents = [
          {
            store = "/persist/var";
            mode = "0755";
          }
          {
            store = "/persist/var/lib";
            mode = "0755";
          }
        ];
      }
    ];

    age.secrets.users-yml = {
      file = cfg.usersFile;
      owner = user;
      group = user;
      mode = "0400";
    };
    age.secrets.jwt = {
      file = cfg.jwtSecretFile;
      owner = user;
      group = user;
      mode = "0400";
    };
    age.secrets.storage-key = {
      file = cfg.storageKeyFile;
      owner = user;
      group = user;
      mode = "0400";
    };
    age.secrets.session = {
      file = cfg.sessionSecretFile;
      owner = user;
      group = user;
      mode = "0400";
    };

    services.authelia.instances.main = {
      enable = true;

      name = "";
      secrets = {
        jwtSecretFile = config.age.secrets.jwt.path;
        storageEncryptionKeyFile = config.age.secrets.storage-key.path;
        sessionSecretFile = config.age.secrets.session.path;
      }
      // lib.optionalAttrs (cfg.oidcHmacSecretFile != null) {
        oidcHmacSecretFile = config.age.secrets.oidc-hmac.path;
        oidcIssuerPrivateKeyFile = config.age.secrets.oidc-issuer.path;
      };
      settings = {

        theme = "dark";
        log.level = "info";
        log.format = "text";
        server.address = "tcp://0.0.0.0:9091/";
        server.endpoints.authz.forward-auth.implementation = "ForwardAuth";

        authentication_backend.refresh_interval = "always";
        authentication_backend.file = {
          path = config.age.secrets.users-yml.path;

          watch = false;
        };
        storage.local.path = "${state}/db.sqlite3";
        notifier.filesystem.filename = "${state}/notification.txt";
        access_control = {
          default_policy = "deny";
          rules = map (
            rule: if rule.subject == [ ] then builtins.removeAttrs rule [ "subject" ] else rule
          ) cfg.accessRules;
        };
        session.cookies = cfg.cookies;

        default_2fa_method = "totp";
        totp = {
          disable = false;
          issuer = factorName;
        };
        webauthn = {
          disable = false;
          display_name = factorName;
        };
      }
      // lib.optionalAttrs (cfg.oidcClients != [ ]) {

        identity_providers.oidc = {
          claims_policies.default.id_token = [
            "groups"
            "email"
            "email_verified"
            "preferred_username"
            "name"
          ];
          clients = map (
            client:
            client
            // lib.optionalAttrs (!(client ? claims_policy)) {
              claims_policy = "default";
            }
          ) cfg.oidcClients;
        };
      };
    };

    age.secrets.oidc-hmac = lib.mkIf (cfg.oidcHmacSecretFile != null) {
      file = cfg.oidcHmacSecretFile;
      owner = user;
      group = user;
      mode = "0400";
    };
    age.secrets.oidc-issuer = lib.mkIf (cfg.oidcIssuerPrivateKeyFile != null) {
      file = cfg.oidcIssuerPrivateKeyFile;
      owner = user;
      group = user;
      mode = "0400";
    };

    systemd.services.authelia = {
      after = [
        "agenix-decrypt.service"
        "restic-bootstrap.service"
      ];
      wants = [ "agenix-decrypt.service" ];

      restartTriggers = [ config.age.secrets.users-yml.file ];
    };
  };
}
