{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ parts, ... }:
    parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem =
        { pkgs, ... }:
        let
          beamPackages = pkgs.beam.packages.erlang_27;
          erlang = beamPackages.erlang;
          elixir = beamPackages.elixir_1_18;
        in
        {
          devShells = {
            default = pkgs.mkShell {
              packages = with pkgs; [
                erlang
                elixir
                nodejs_22

                # tools
                flyctl
                inotify-tools
                elixir_ls
                watchman
              ];

              # useful Elixir defaults
              env = {
                ERL_AFLAGS = "+pc unicode -kernel shell_history enabled -proto_dist inet6_tcp";
                ELIXIR_ERL_OPTIONS = "+fnu +sssdio 128";
              };

              shellHook = ''
                # export other secret envs
                export $(cat .env | xargs)
              '';
            };
          };
        };
    };
}
