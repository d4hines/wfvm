{ pkgs
, diskImageSize ? "70G"
, windowsImage ? null
, autoUnattendParams ? {}
, impureMode ? false
, installCommands ? []
, users ? {}
# autounattend always installs index 1, so this default is backward-compatible
, imageSelection ? "Windows 10 Pro"
, efi ? true
, ...
}@attrs:

let
  lib = pkgs.lib;
  utils = import ./utils.nix { inherit pkgs efi; };
  inherit (pkgs) guestfs-tools;

  # p7zip on >20.03 has known vulns but we have no better option
  p7zip = pkgs.p7zip.overrideAttrs(old: {
    meta = old.meta // {
      knownVulnerabilities = [];
    };
  });

  runQemuCommand = name: command: (
    pkgs.runCommand name { buildInputs = [ p7zip utils.qemu guestfs-tools ]; }
      (
        ''
          if ! test -f; then
            echo "KVM not available, bailing out" >> /dev/stderr
            exit 1
          fi
        '' + command
      )
  );

  windowsIso = if windowsImage != null then windowsImage else pkgs.requireFile rec {
    name = "Win10_21H2_English_x64.iso";
    sha256 = "0kr3m0bjy086whcbssagsshdxj6lffcz7wmvbh50zhrkxgq3hrbz";
    message = "Get ${name} from https://www.microsoft.com/en-us/software-download/windows10ISO";
  };

  virtioWinIso = pkgs.fetchurl {
    url = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.229-1/virtio-win.iso";
    sha256 = "1q5vrcd70kya4nhlbpxmj7mwmwra1hm3x7w8rzkawpk06kg0v2n8";
  };

  openSshServerPackage = pkgs.fetchurl {
    url = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/V8.6.0.0p1-Beta/OpenSSH-Win64.zip";
    sha256 = "1dw6n054r0939501dpxfm7ghv21ihmypdx034van8cl21gf1b4lz";
  };

  autounattend = import ./autounattend.nix (
    attrs // {
      inherit pkgs;
      users = users // {
        wfvm = {
          password = "1234";
          description = "WFVM Administrator";
          groups = [
            "Administrators"
          ];
        };
      };
    }
  );

  bundleInstaller = pkgs.callPackage ./bundle {};

  # Packages required to drive installation of other packages
  bootstrapPkgs =
    runQemuCommand "bootstrap-win-pkgs.img" ''
      7z x -y ${virtioWinIso} -opkgs/virtio

      cp ${bundleInstaller} pkgs/"$(stripHash "${bundleInstaller}")"

      # Install optional windows features
      cp ${openSshServerPackage} pkgs/OpenSSH-Win64.zip

      # SSH setup script goes here because windows XML parser sucks
      cp ${./install-ssh.ps1} pkgs/install-ssh.ps1
      cp ${autounattend.setupScript} pkgs/setup.ps1

      virt-make-fs --partition --type=fat pkgs/ $out
    '';

  installScript = pkgs.writeScript "windows-install-script" (
    let
      qemuParams = utils.mkQemuFlags (lib.optional (!impureMode) "-display none" ++ [
        # "CD" drive with bootstrap pkgs
        "-drive"
        "id=virtio-win,file=${bootstrapPkgs},if=none,format=raw,readonly=on"
        "-device"
        "usb-storage,drive=virtio-win"
        # USB boot
        "-drive"
        "id=win-install,file=${if efi then "usb" else "cd"}image.img,if=none,format=raw,readonly=on,media=${if efi then "disk" else "cdrom"}"
        "-device"
        "usb-storage,drive=win-install"
        # Output image
        "-drive"
        "file=c.img,index=0,media=disk,if=virtio,cache=unsafe"
        # Network
        "-netdev user,id=n1,net=192.168.1.0/24,restrict=on"
      ]);
    in
      ''
        #!${pkgs.runtimeShell}
        set -euxo pipefail
        export PATH=${lib.makeBinPath [ p7zip utils.qemu guestfs-tools pkgs.wimlib ]}:$PATH

        # Create a bootable "USB" image
        # Booting in USB mode circumvents the "press any key to boot from cdrom" prompt
        #
        # Also embed the autounattend answer file in this image
        mkdir -p win
        mkdir -p win/nix-win
        7z x -y ${windowsIso} -owin

        # Split image so it fits in FAT32 partition
        wimsplit win/sources/install.wim win/sources/install.swm 4070
        rm win/sources/install.wim

        cp ${autounattend.autounattendXML} win/autounattend.xml

        ${if efi then ''
        virt-make-fs --partition --type=fat win/ usbimage.img
        '' else ''
        ${pkgs.cdrkit}/bin/mkisofs -iso-level 4 -l -R -udf -D -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -hide boot.catalog -eltorito-alt-boot -o cdimage.img win/
        ''}
        rm -rf win

        # Qemu requires files to be rw
        qemu-img create -f qcow2 c.img ${diskImageSize}
        qemu-system-x86_64 ${lib.concatStringsSep " " qemuParams}
      ''
  );

  baseImage = pkgs.runCommand "RESTRICTDIST-windows.img" {} ''
    ${installScript}
    mv c.img $out
  '';

  finalImage = builtins.foldl' (acc: v: pkgs.runCommand "RESTRICTDIST-${v.name}.img" {
    buildInputs = with utils; [
      qemu win-wait win-exec win-put
    ] ++ (v.buildInputs or []);
  } (let
    script = pkgs.writeScript "${v.name}-script" v.script;
    qemuParams = utils.mkQemuFlags (lib.optional (!impureMode) "-display none" ++ [
      # Output image
      "-drive"
      "file=c.img,index=0,media=disk,if=virtio,cache=unsafe"
      # Network - enable SSH forwarding
      "-netdev user,id=n1,net=192.168.1.0/24,restrict=on,hostfwd=tcp::2022-:22"
    ]);

  in ''
    set -x
    # Create an image referencing the previous image in the chain
    qemu-img create -F qcow2 -f qcow2 -b ${acc} c.img

    set -m
    qemu-system-x86_64 ${lib.concatStringsSep " " qemuParams} &

    win-wait

    echo "Executing script to build layer..."
    ${script}
    echo "Layer script done"

    echo "Shutting down..."
    win-exec 'shutdown /s'
    echo "Waiting for VM to terminate..."
    fg
    echo "Done"

    mv c.img $out
  '')) baseImage (
    [
      {
        name = "DisablePasswordExpiry";
        script = ''
          win-exec 'wmic UserAccount set PasswordExpires=False'
        '';
      }
    ] ++
    installCommands
  );

in

# impureMode is meant for debugging the base image, not the full incremental build process
if !(impureMode) then finalImage else assert installCommands == []; installScript
