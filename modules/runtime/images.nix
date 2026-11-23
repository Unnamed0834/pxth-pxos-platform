
{
  arcane = "docker.io/getarcaneapp/manager:v3.1.0@sha256:4151e7bc42ddec87c2ce5534d7611297465e2b05e6472f12382073eeca878c8e";
  bazarr = "lscr.io/linuxserver/bazarr:latest@sha256:e0c5d45965242830c5eeddaafe9ae2b5e8ca3f6c01ecda9ee9364f550921dc50";
  bgutil = "docker.io/brainicism/bgutil-ytdlp-pot-provider:2.0.2@sha256:d7d34108b76e52c7d3b575fe9e797e4bf41c1b2a08f80c5292eff6f851ce8472";
  byparr = "ghcr.io/thephaseless/byparr:3.1.1@sha256:c66fa161187b8fa527bfad7eefa2647ea1c553f77df68cbffd6fe83366d1787b";

  gluetun = "docker.io/qmcgaw/gluetun@sha256:c6a0f3dc7cf9aba18a057d7d34b2e34d68063cd06a32e5869db34613c430a26a";
  jdownloader = "docker.io/jlesage/jdownloader-2:v26.09.1@sha256:bd6cd2fdc72818f30207e677b33cd7f1b425048c4e7132624e541e99f992be4c";

  jellyfin = {
    image = "docker.io/jellyfin/jellyfin:12.4";
    imageDigest = "sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771";
  };

  navidrome = "docker.io/deluan/navidrome:0.64.2@sha256:38dc2727bfcfd5ede290f8ada114fc90368146f265ae4701ddddbcbe2a44ee52";
  nixosNix = "docker.io/nixos/nix:2.35.6@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed";

  openwebui = "ghcr.io/open-webui/open-webui:v0.13.4@sha256:d5168bfbc28609eff5bea1b438dd864cf64d185cf6582c02244865e18385b901";
  pgvector = "docker.io/pgvector/pgvector@sha256:a97d77306ff47cc1d8add4d000cec2207da2e110746318df3137ce53c337ca30";
  prowlarr = "lscr.io/linuxserver/prowlarr:3.0.2.5780-ls169@sha256:45117ba8439e2337a92ffe38a451a4dafc0be771754d05d88cdf102419d09646";
  qbittorrent = "lscr.io/linuxserver/qbittorrent:latest@sha256:3d4c4545d51a690a0df15a2ff99038823a88a9822df8e794526447b9afbd7384";
  radarr = "lscr.io/linuxserver/radarr:latest@sha256:044788f5508b7f67a3e0368cdd142c77c4d4cd5aec2efaba53e1a68b6b6231e7";
  recyclarr = "ghcr.io/recyclarr/recyclarr:8.8.1@sha256:3e9c41b9ec29bbf65fe846864058730d321a21f7695d8c0d9437b73e34d50ad9";

  resume = "ghcr.io/reactive-resume/reactive-resume:v6.1.1@sha256:6390bd3dfa2e1acd41dceef3e4be6724f4564346bfc9d0cd54316552cca9545d";

  resumePostgres = "docker.io/library/postgres:18@sha256:e754b839f447639b7004895f4d8a4bfcb4e9dbe3a1bc035f27f646562a16fd61";
  sonarr = "lscr.io/linuxserver/sonarr:latest@sha256:c7d1df25e428da6c9ace05daea0d34e59522978a3843ea1944812f855af4086c";
  vllm = "vllm/vllm-openai:qwen38-flash-next@sha256:fc120ece0a388cc0aa1caad4a9f1cd92113484ab7ec2fd0efadd62585be05bf8";

  vllm1x = "ghcr.io/example/qwen38-flash-next@sha256:0000000000000000000000000000000000000000000000000000000000000000";
  ytdlp = "docker.io/jauderho/yt-dlp:latest@sha256:22751598ef358a8a3c20acd133364ba1adacaf11e9cc2e52be5fd00e6c7c012a";
  ytdlSub = "ghcr.io/jmbannon/ytdl-sub:latest@sha256:e5a25257d6df295c93ca119287e6b3090e38d26cf94e8eca11e4819f616285b4";

  opencode = {
    version = "2.3.2";
    hash = "sha256-hFRo41qlorV0lFoLlmdeZMYE9Sec7ZqnJFBo2MC29rs=";
  };

  wazuh = {
    tag = "5.0.0-rc2";
    agentDebUrl = "https://packages.wazuh.com/5.x/apt/pool/main/w/wazuh-agent/wazuh-agent_5.0.0-rc2_amd64.deb";
    agentDebHash = "sha256-ILSXjYz/N7ViFHacWuR3vFRTd9FVhuUBCI9buV3QNDs=";
  };
}
