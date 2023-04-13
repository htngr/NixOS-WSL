{ config, lib, pkgs, ... }:
with builtins; with lib; {

  config = mkIf config.wsl.enable (
    let
      mkTarball = pkgs.callPackage "${lib.cleanSource pkgs.path}/nixos/lib/make-system-tarball.nix";

      pkgs2storeContents = map (x: { object = x; symlink = "none"; });

      rootfs = let tarball = config.system.build.tarball; in "${tarball}/tarball/${tarball.fileName}.tar${tarball.extension}";

      fakeSystemctl = pkgs.writeScript "systemctl" ''
        ${pkgs.busybox}/bin/true
      '';

      installer = pkgs.writeScript "installer.sh" ''
        #!${pkgs.busybox}/bin/sh
        BASEPATH=$PATH
        export PATH=$BASEPATH:${lib.makeBinPath [ pkgs.busybox ]} # Add utils to path

        set -e
        cd /

        echo "Unpacking root file system..."
        # busybox tar sometimes doesnt overwrite files
        ${pkgs.pv}/bin/pv ${rootfs} | ${pkgs.gnutar}/bin/tar xz

        echo "Activating nix configuration..."
        LANG="C.UTF-8" /nix/var/nix/profiles/system/activate
        PATH=$BASEPATH:/run/current-system/sw/bin # Use packages from target system

        echo "Cleaning up installer files..."
        nix-collect-garbage
        rm /nix-path-registration

        echo "Optimizing store..."
        nix-store --optimize

        # Don't package the shell here, it's contained in the rootfs
        exec ${builtins.unsafeDiscardStringContext pkgs.wslNativeUtils}/bin/systemd-shim "$@"
        
      '';

      # Set installer.sh as the root shell
      passwd = pkgs.writeText "passwd" ''
        root:x:0:0:System administrator:/root:${installer}
      '';

      wsl-conf = pkgs.writeText "wsl.conf" (lib.generators.toINI { } (config.wsl.wslConf // {
        boot.systemd = true;
        user.default = "root";
      }));
    in
    {

      system.build.systemd-installer = mkTarball {
        fileName = "nixos-wsl-installer";
        compressCommand = "gzip";
        compressionExtension = ".gz";
        extraArgs = "--hard-dereference";

        storeContents = pkgs2storeContents [ installer ];

        contents = [
          { source = wsl-conf; target = "/etc/wsl.conf"; }
          { source = config.environment.etc."fstab".source; target = "/etc/fstab"; }
          { source = passwd; target = "/etc/passwd"; }
          { source = "${pkgs.busybox}/bin/busybox"; target = "/bin/sh"; }
          # { source = "${pkgs.busybox}/bin/busybox"; target = "/bin/grep"; }
          { source = "${pkgs.busybox}/bin/busybox"; target = "/bin/mount"; }
          # { source = "${pkgs.busybox}/bin/true"; target = "/bin/systemctl"; }
          # { source = "${fakeSystemctl}"; target = "/bin/systemctl"; }
          # { source = "${fakeSystemctl}"; target = "/lib/systemd/systemctl"; }
          { source = "${installer}"; target = "/nix/nixos-wsl/entrypoint"; } # only needed for tests?
          { source = "${installer}"; target = "/sbin/init"; }
        ];

        extraCommands = pkgs.writeShellScript "prepare" ''
          export PATH=$PATH:${pkgs.coreutils}/bin
          mkdir -p bin
          ln -s /init bin/wslpath
        '';
      };

    }
  );

}
