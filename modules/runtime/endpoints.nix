{
  hosts = {
    storage = "198.51.100.10";
    bsn = "192.0.2.31";
    dev = "192.0.2.32";
    git = "198.51.100.21";
    r1 = "198.51.100.22";
    r2 = "198.51.100.23";
    metrics = "198.51.100.24";
    app-01 = "198.51.100.25";
    cache = "198.51.100.26";
    artifacts = "198.51.100.27";
    app-portal = "198.51.100.28";
    app-ide = "198.51.100.29";
    infer-01 = "198.51.100.30";
    gateway-01 = "198.51.100.31";
    game-01 = "198.51.100.32";
    siteCApp = "198.51.100.41";
    siteBApp = "198.51.100.42";
    siteBGs1 = "198.51.100.43";
  };

  ports = {
    chat = 8000;
    admit = 8002;
    vllm = 8001;
    vllm1x = 8015;
    inkling2 = 8016;
    slm = 8010;
    gemma12 = 8011;
    memory = 8006;
    archive = 8012;
    archiveViz = 8014;
    embed = 8020;
    healthPage = 8090;
    healthAgent = 8091;
    llamaSlots = [ 8095 ];
    authelia = 9091;
    gatewayClient = 8765;
    fluxerRail = 8094;
    hy4 = 8013;
  };

  inference = {
    profile = "vllm1x";
  };
}
