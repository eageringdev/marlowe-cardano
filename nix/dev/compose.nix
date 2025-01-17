{ sqitchPg, runCommand, writeShellScriptBin, writeText, lib, glibcLocales, networks }:
let
  network = networks.preview;
  run-sqitch = writeShellScriptBin "run-sqitch" ''
    export PATH="$PATH:${lib.makeBinPath [ sqitchPg ]}"
    export LOCALE_ARCHIVE="${glibcLocales}/lib/locale/locale-archive"
    cd /src/marlowe-chain-sync
    exec sqitch deploy "$@"
  '';

  run-sqitch-marlowe-indexer = writeShellScriptBin "run-sqitch-marlowe-indexer" ''
    export PATH="$PATH:${lib.makeBinPath [ sqitchPg ]}"
    export LOCALE_ARCHIVE="${glibcLocales}/lib/locale/locale-archive"
    cd /src/marlowe-runtime/marlowe-indexer
    exec sqitch deploy "$@"
  '';

  run-local-service = project: version: prog: writeShellScriptBin "run-${prog}" ''
    set -e
    PROG=${lib.escapeShellArg prog}
    PKG=${lib.escapeShellArg project}-${lib.escapeShellArg version}
    cd /src
    # Hard-coding linux because this won't work on Mac anyway.
    # TODO find a setup that works on MacOS
    BIN=./dist-newstyle/build/x86_64-linux/ghc-8.10.7/$PKG/x/$PROG/build/$PROG/$PROG
    exec -a $PROG $BIN "$@"
  '';

  symlinks = runCommand "symlinks" { } ''
    mkdir -p $out
    ln -sv ${run-sqitch}/bin/run-sqitch $out
    ln -sv ${run-sqitch-marlowe-indexer}/bin/run-sqitch-marlowe-indexer $out
    ln -sv ${run-local-service "marlowe-chain-sync" "0.0.0.0" "marlowe-chain-indexer"}/bin/run-marlowe-chain-indexer $out
    ln -sv ${run-local-service "marlowe-chain-sync" "0.0.0.0" "chainseekd"}/bin/run-chainseekd $out
    ln -sv ${run-local-service "marlowe-runtime" "0.0.0.0" "marlowe-sync"}/bin/run-marlowe-sync $out
    ln -sv ${run-local-service "marlowe-runtime" "0.0.0.0" "marlowe-history"}/bin/run-marlowe-history $out
    ln -sv ${run-local-service "marlowe-runtime" "0.0.0.0" "marlowe-discovery"}/bin/run-marlowe-discovery $out
    ln -sv ${run-local-service "marlowe-runtime" "0.0.0.0" "marlowe-tx"}/bin/run-marlowe-tx $out
    ln -sv ${run-local-service "marlowe-runtime" "0.0.0.0" "marlowe-web-server"}/bin/run-marlowe-web-server $out
    ln -sv ${run-local-service "marlowe-runtime" "0.0.0.0" "marlowe-indexer"}/bin/run-marlowe-indexer $out
  '';

  node-service = {
    image = "inputoutput/cardano-node:1.35.4";

    environment = [
      "NETWORK=${network.name}"
    ];

    volumes = [
      "shared:/ipc"
      "node-db:/opt/cardano/data"
    ];

    # This should be in the dockerfile
    healthcheck = {
      test = "socat -u OPEN:/dev/null UNIX-CONNECT:/ipc/node.socket";
      interval = "10s";
      timeout = "5s";
      retries = 10;
    };
  };

  dev-service = { ports, depends_on, command }: {
    inherit command;
    image = "alpine:3.16.2";
    volumes = [
      "./:/src"
      "/nix:/nix"
      "${symlinks}:/exec"
      "shared:/ipc"
    ];
    restart = "unless-stopped";
    ports = map toString ports;
    healthcheck = {
      test = "netstat -tulpn | grep LISTEN | grep ${toString (builtins.head ports)}";
      interval = "10s";
      timeout = "5s";
      retries = 5;
    };
    depends_on = lib.genAttrs depends_on (_: { condition = "service_healthy"; });
  };

  chain-indexer-service = {
    image = "alpine:3.16.2";
    volumes = [
      "./:/src"
      "/nix:/nix"
      "${symlinks}:/exec"
      "shared:/ipc"
    ];
    restart = "unless-stopped";
    depends_on = {
      "postgres" = { condition = "service_healthy"; };
      "node" = { condition = "service_healthy"; };
    };
    command = [
      "/exec/run-marlowe-chain-indexer"
      "--testnet-magic"
      (builtins.toString network.magic)
      "--socket-path"
      "/ipc/node.socket"
      "--database-uri"
      "postgresql://postgres@postgres/chain"
      "--genesis-config-file"
      network.nodeConfig.ByronGenesisFile
      "--genesis-config-file-hash"
      network.nodeConfig.ByronGenesisHash
      "--shelley-genesis-config-file"
      network.nodeConfig.ShelleyGenesisFile
      "--log-config-file"
      "./marlowe-chain-indexer.log.config"
    ];
    healthcheck = {
      test = "/exec/run-sqitch -h postgres";
      timeout = "20s";
      retries = 0;
    };
  };

  marlowe-indexer-service = {
    image = "alpine:3.16.2";
    volumes = [
      "./:/src"
      "/nix:/nix"
      "${symlinks}:/exec"
      "shared:/ipc"
    ];
    restart = "unless-stopped";
    depends_on = {
      "postgres" = { condition = "service_healthy"; };
      "chainseekd" = { condition = "service_healthy"; };
    };
    command = [
      "/exec/run-marlowe-indexer"
      "--chain-seek-host"
      "chainseekd"
      "--log-config-file"
      "./marlowe-indexer.log.config"
      "--database-uri"
      "postgresql://postgres@postgres/chain"
    ];
    healthcheck = {
      test = "/exec/run-sqitch-marlowe-indexer -h postgres";
      timeout = "20s";
      retries = 0;
    };
  };

  chainseekd-service = dev-service {
    ports = [ 3715 3716 3720 ];
    depends_on = [ "postgres" "node" "marlowe-chain-indexer" ];
    command = [
      "/exec/run-chainseekd"
      "--testnet-magic"
      (builtins.toString network.magic)
      "--socket-path"
      "/ipc/node.socket"
      "--database-uri"
      "postgresql://postgres@postgres/chain"
      "--host"
      "0.0.0.0"
      "--log-config-file"
      "./chainseekd.log.config"
    ];
  };

  sync-service = dev-service {
    ports = [ 3724 3725 ];
    depends_on = [ "marlowe-indexer" "postgres" ];
    command = [
      "/exec/run-marlowe-sync"
      "--database-uri"
      "postgresql://postgres@postgres/chain"
      "--host"
      "0.0.0.0"
      "--log-config-file"
      "./marlowe-sync.log.config"
    ];
  };

  history-service = dev-service {
    ports = [ 3717 3718 3719 ];
    depends_on = [ "chainseekd" ];
    command = [
      "/exec/run-marlowe-history"
      "--chain-seek-host"
      "chainseekd"
      "--host"
      "0.0.0.0"
      "--log-config-file"
      "./marlowe-history.log.config"
    ];
  };

  discovery-service = dev-service {
    ports = [ 3721 3722 ];
    depends_on = [ "chainseekd" ];
    command = [
      "/exec/run-marlowe-discovery"
      "--chain-seek-host"
      "chainseekd"
      "--host"
      "0.0.0.0"
      "--log-config-file"
      "./marlowe-discovery.log.config"
    ];
  };

  tx-service = dev-service {
    ports = [ 3723 ];
    depends_on = [ "chainseekd" ];
    command = [
      "/exec/run-marlowe-tx"
      "--chain-seek-host"
      "chainseekd"
      "--host"
      "0.0.0.0"
      "--log-config-file"
      "./marlowe-tx.log.config"
    ];
  };

  web-service = dev-service {
    ports = [ 8080 ];
    depends_on = [ "marlowe-sync" "marlowe-tx" ];
    command = [
      "/exec/run-marlowe-web-server"
      "--history-host"
      "marlowe-sync"
      "--history-sync-port"
      "3724"
      "--discovery-sync-port"
      "3725"
      "--discovery-host"
      "marlowe-sync"
      "--tx-host"
      "marlowe-tx"
      "--enable-open-api"
      "--access-control-allow-origin-all"
    ];
  };

  spec = {
    services.postgres = {
      image = "postgres:11.5-alpine";

      # TODO translate from attrset
      environment = [
        "POSTGRES_LOGGING=true"
        "POSTGRES_USER=postgres"
        "POSTGRES_HOST_AUTH_METHOD=trust"
        "TZ=UTC"
      ];

      # TODO strucutred volume definition
      # TODO Connect volumes here to top-level volumes
      volumes = [
        "postgres:/var/lib/postgresql/data"
        "./postgres/init.sql:/docker-entrypoint-initdb.d/init.sql"
        "./:/src"
        "/nix:/nix"
        "${symlinks}:/exec"
      ];

      # TODO enum
      restart = "unless-stopped";

      # this should be in the dockerfile...
      healthcheck = {
        test = [ "CMD" "pg_isready" "-U" "postgres" ];
        # TODO structured
        interval = "10s";
        timeout = "5s";
        retries = 5;
      };

      logging = {
        # enum
        driver = "json-file";
        options = {
          max-size = "200k";
          max-file = "10";
        };
      };
    };

    volumes.postgres = null;

    services.marlowe-chain-indexer = chain-indexer-service;
    services.chainseekd = chainseekd-service;
    services.marlowe-history = history-service;
    services.marlowe-discovery = discovery-service;
    services.marlowe-tx = tx-service;
    services.web = web-service;
    services.marlowe-indexer = marlowe-indexer-service;
    services.marlowe-sync = sync-service;

    services.node = node-service;
    volumes.shared = null;
    volumes.node-db = null;
  };
in
writeText "compose.yaml" (builtins.toJSON spec)
