{ config, pkgs, lib, ... }:
with builtins; with lib;
let
  pkgs2storeContents = map (x: { object = x; symlink = "none"; });

  nixpkgs = lib.cleanSource pkgs.path;

  channelSources = pkgs.runCommand "nixos-${config.system.nixos.version}"
    { preferLocalBuild = true; }
    ''
      mkdir -p $out
      cp -prd ${nixpkgs.outPath} $out/nixos
      chmod -R u+w $out/nixos
      if [ ! -e $out/nixos/nixpkgs ]; then
        ln -s . $out/nixos/nixpkgs
      fi
      echo -n ${toString config.system.nixos.revision} > $out/nixos/.git-revision
      echo -n ${toString config.system.nixos.versionSuffix} > $out/nixos/.version-suffix
      echo ${toString config.system.nixos.versionSuffix} | sed -e s/pre// > $out/nixos/svn-revision
    '';

  # discardIfUseRemote = x: if cfg.useRemoteStore then builtins.unsafeDiscardStringContext x else x;

  preparer = pkgs.writeShellScriptBin "wsl-prepare" ''
    set -ex

    export PATH=$PATH:${lib.makeBinPath [config.nix.package]}

    # mkdir -m 0755 ./bin ./etc
    # mkdir -m 1777 ./tmp

    nix-store --store `pwd` --load-db < ./nix-path-registration
    rm ./nix-path-registration
    nix-env --store `pwd` -p ./nix/var/nix/profiles/system --set ${config.system.build.toplevel}

    # Set channel
    mkdir -p ./nix/var/nix/profiles/per-user/root
    nix-env --store `pwd` -p ./nix/var/nix/profiles/per-user/root/channels --set ${channelSources}
    mkdir -m 0700 -p ./root/.nix-defexpr
    ln -s /nix/var/nix/profiles/per-user/root/channels ./root/.nix-defexpr/channels

    ${lib.optionalString config.wsl.tarball.includeConfig ''
      # Copy the system configuration
      mkdir -p ./etc/nixos/nixos-wsl
      cp -R ${lib.cleanSource ../.}/. ./etc/nixos/nixos-wsl
      mv ./etc/nixos/nixos-wsl/configuration.nix ./etc/nixos/configuration.nix
      # Patch the import path to avoid having a flake.nix in /etc/nixos
      sed -i 's|import \./default\.nix|import \./nixos-wsl|' ./etc/nixos/configuration.nix
    ''}

    ${lib.optionalString cfg.useRemoteStore ''
      chmod -R 700 ./nix/store
      rm -r ./nix/store
    ''}
  '';

  installer = pkgs.writeScript "installer.sh" ''
    #!/bin/sh
    set -ex

    function cleanup {
      echo "testtttttttttttttttttttttt" 1>&2
      echo "testtttttttttttttttttttttt" 2>&1
    }
    trap cleanup EXIT

    ${lib.optionalString cfg.useRemoteStore "/bin/mount-remote-store"}

    echo "Starting systemd..."
    exec ${pkgs.wslNativeUtils}/bin/systemd-shim "$@"
  '';

  cfg = config.wsl;
  mnt = cfg.wslConf.automount;

  mountRemoteStore = pkgs.writeScript "mount-remote-store" ''
    #!/bin/sh
    set -ex

    if [ ! -d ${mnt.root}/wsl/nix/store ] || [ ! -d ${mnt.root}/wsl/nix/var/nix/daemon-socket ] ; then
      echo "Remote store is not mounted on ${mnt.root}/wsl/nix" >&2
      exit 1
    fi
    if [ ! -S ${mnt.root}/wsl/nix/var/nix/daemon-socket/socket ] ; then
      echo "Remote nix-daemon is not running." >&2
      exit 1
    fi

    echo "Mounting remote /nix/store..."
    /bin/mkdir -p /nix/{store,var/nix/daemon-socket} || true
    /bin/mount --bind --ro ${mnt.root}/wsl/nix/store /nix/store
    /bin/mount --bind ${mnt.root}/wsl/nix/var/nix/daemon-socket /nix/var/nix/daemon-socket
  '';

  staticFiles = [
    { inherit (config.environment.etc."wsl.conf") source; target = "/etc/wsl.conf"; }
    { source = installer; target = "/sbin/init"; }
    { source = "${pkgs.pkgsStatic.busybox}/bin/busybox"; target = "/bin/mount"; }
  ] ++
  optionals cfg.useRemoteStore [
    { source = "${pkgs.pkgsStatic.busybox}/bin/busybox"; target = "/bin/mkdir"; }
    { source = "${pkgs.pkgsStatic.bash}/bin/bash"; target = "/bin/sh"; }
    { source = mountRemoteStore; target = "/bin/mount-remote-store"; }
  ];
in
{
  options.wsl.useRemoteStore = mkOption {
    type = types.bool;
    default = false;
    description = "Use remote store / daemon on <wsl.wslconf.automount.root>/wsl/nix and dont ship /nix/store";
  };

  config = mkIf cfg.enable (mkMerge [

    {

      assertions = [{
        assertion = cfg.nativeSystemd;
        message = "wsl.nativeSystemd must be enabled";
      }];

      system.build.systemd-tarball = pkgs.callPackage "${nixpkgs}/nixos/lib/make-system-tarball.nix" {

        contents = [
          { source = installer; target = "/nix/nixos-wsl/entrypoint"; } # needed for tests?
        ] ++ staticFiles;

        fileName = "nixos-wsl-${pkgs.hostPlatform.system}";

        storeContents = pkgs2storeContents [
          config.system.build.toplevel
          channelSources
          preparer
        ];


        extraCommands = "${preparer}/bin/wsl-prepare";
        extraArgs = "--hard-dereference";

        # Use gzip
        compressCommand = "gzip";
        compressionExtension = ".gz";
      };

    }

    (mkIf cfg.useRemoteStore {

      assertions = [{
        assertion = cfg.useRemoteStore -> mnt.enabled;
        message = "wsl.wslconf.automount.enabled must be true in order to use a remote /nix/store";
      }];


      # fileSystems = {
      #   "/nix/store" = {
      #     device = "/mnt/wsl/nix/store";
      #     options = [ "bind" ];
      #   };
      #   "/nix/var/nix/daemon-socket" = {
      #     device = "/mnt/wsl/nix/var/nix/daemon-socket";
      #     options = [ "bind" ];
      #   };
      # };

      environment.etc."wsl.conf".enable = mkForce false;
      systemd.services.nix-daemon.enable = mkForce false;

      system.activationScripts = {

        populateBin = mkForce (stringAfter [ "etc" ] ''
          echo "setting up files for WSL..."
          ln -sf /init /bin/wslpath
          ${pipe staticFiles [
            (map ({source, target}: "cp -af ${source} ${target}"))
            (concatStringsSep "\n")
          ]}
        '');
        shimSystemd.text = mkForce "";
        setupLogin.text = mkForce "";
      };

    })

  ]);
}
