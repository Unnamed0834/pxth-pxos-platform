let
  ep = import ../runtime/endpoints.nix;
in
{
  siteC = {
    upstream = "${ep.hosts.siteCApp}:${toString ep.ports.authelia}";
    issuer = "https://auth.app.example.com";
    forwardAuthFrom = [
      "127.0.0.1"
      ep.hosts.siteCApp
    ];
    cookies = [
      {
        domain = "app.example.com";
        authelia_url = "https://auth.app.example.com";
        default_redirection_url = "https://app.example.com";
      }
    ];
    accessRules = [
      {
        domain = [
          "*.app.example.com"
        ];
        policy = "one_factor";
        subject = [
          "group:owner"
          "group:siteC"
        ];
      }
    ];
  };

  siteB = {
    upstream = "${ep.hosts.siteBApp}:${toString ep.ports.authelia}";
    issuer = "https://auth.app.example.org";
    forwardAuthFrom = [
      "127.0.0.1"
      ep.hosts.siteBApp
    ];
    cookies = [
      {
        domain = "app.example.org";
        authelia_url = "https://auth.app.example.org";
        default_redirection_url = "https://app.example.org";
      }
    ];
    accessRules = [
      {
        domain = [
          "*.app.example.org"
        ];
        policy = "one_factor";
        subject = [
          "group:owner"
          "group:siteB"
        ];
      }
    ];
  };
}
