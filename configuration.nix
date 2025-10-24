{ config, pkgs, ros-pkgs, lib, ... }:

let
  user      = "admin";
  password  = "password";
  hostname  = "68fb95bbc9331914f5360199";
  repoName  = "polyflow_robot_${hostname}";
  homeDir   = "/home/${user}";
  wsDir     = "${homeDir}/${repoName}/workspace";
  rosPy = ros-pkgs.python3;
  sp    = ros-pkgs.python3.sitePackages;   


 webrtcLauncher = pkgs.writeShellScript "webrtc-launch.sh" ''
    #!/usr/bin/env bash
    set -eo pipefail

    # Keep Nix’s ROS plugins visible (prepend Nix store paths)
    export PYTHONPATH="${ros-pkgs.rosPackages.humble.ros2cli}/${sp}:${ros-pkgs.rosPackages.humble.ros2launch}/${sp}:${ros-pkgs.rosPackages.humble.launch}/${sp}:${ros-pkgs.rosPackages.humble.launch-ros}/${sp}:${ros-pkgs.rosPackages.humble.ros-base}/${sp}:$PYTHONPATH"
    export AMENT_PREFIX_PATH="${ros-pkgs.rosPackages.humble.ros2launch}:${ros-pkgs.rosPackages.humble.launch}:${ros-pkgs.rosPackages.humble.launch-ros}:${ros-pkgs.rosPackages.humble.ros-base}:$AMENT_PREFIX_PATH"

    # Source your colcon workspace (allow unset vars during env hook eval)
    if [ -f "${wsDir}/install/local_setup.sh" ]; then
      echo "[webrtc] Sourcing ${wsDir}/install/local_setup.sh"
      set +u
      . "${wsDir}/install/local_setup.sh"
      set -u || true
    else
      echo "[webrtc] Missing ${wsDir}/install/local_setup.sh; did build succeed?" >&2
      exit 1
    fi

    echo "[webrtc] Launching…"
    exec ${ros-pkgs.rosPackages.humble.ros2cli}/bin/ros2 launch webrtc webrtc.launch.py
  '';
in
{
  ################################################################################
  # Hardware / boot
  ################################################################################
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x: super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  imports = [
    "${builtins.fetchGit {
      url = "https://github.com/NixOS/nixos-hardware.git";
      rev = "26ed7a0d4b8741fe1ef1ee6fa64453ca056ce113";
    }}/raspberry-pi/4"
  ];

  boot = {
    kernelPackages = ros-pkgs.linuxKernel.packages.linux_rpi4;
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  ################################################################################
  # System basics
  ################################################################################
  system.autoUpgrade.flags = [ "--max-jobs" "1" "--cores" "1" ];

  networking = {
    hostName = hostname;
    networkmanager.enable = true;
    nftables.enable = true;
  };

  services.openssh.enable = true;
  services.timesyncd.enable = true;
  services.timesyncd.servers = [ "pool.ntp.org" ];
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  hardware.enableRedistributableFirmware = true;
  system.stateVersion = "23.11";

  # keep a copy of this file on the target (optional)
  environment.etc."nixos/configuration.nix" = {
    source = ./configuration.nix;
    mode = "0644";
  };

  ################################################################################
  # Users
  ################################################################################
  users.mutableUsers = false;
  users.users.${user} = {
    isNormalUser = true;
    password = password;
    extraGroups = [ "wheel" ];
    home = homeDir;
  };
  security.sudo.wheelNeedsPassword = false;

  ################################################################################
  # Packages
  # - ros2 binary: ros-humble.ros2cli
  # - launch plugin (python): ros-humble.ros2launch
  # - base runtime: ros-humble.ros-base
  ################################################################################
  environment.systemPackages = with ros-pkgs; with rosPackages.humble; [
    pkgs.vim
    pkgs.git
    pkgs.wget
    pkgs.inetutils

    # ROS 2
    ros2cli          # provides /bin/ros2
    ros2launch       # python plugin implementing `ros2 launch`
    launch
    ros-base         # (includes core + common tools)

    # Build tools if you really want to colcon at runtime:
    pkgs.python3
    pkgs.colcon      # alias to colcon-common-extensions in many pkgs sets
  ];

  ################################################################################
  # Services (patched)
  ################################################################################

  # 1 Setup: clone/pull + colcon build
  systemd.services.polyflow-setup = {
    description = "Clone/update Polyflow robot repo and colcon build";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "time-sync.target" ];
    wants = [ "network-online.target" "time-sync.target" ];

    path = with pkgs; [ git colcon python3 ros-pkgs.rosPackages.humble.ros2cli ];

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "users";
      WorkingDirectory = homeDir;
      StateDirectory = "polyflow";
      StandardOutput = "journal";
      StandardError  = "journal";
    };

    script = ''
      set -eo pipefail

      export HOME=${homeDir}

      if [ -d "${homeDir}/${repoName}" ]; then
        echo "[setup] Repo exists; pulling latest…"
        cd "${homeDir}/${repoName}"
        git pull --ff-only
      else
        echo "[setup] Cloning repo…"
        git config --global --unset https.proxy || true
        git clone "https://github.com/drewswinney/${repoName}.git" "${homeDir}/${repoName}"
        chown -R ${user}:users "${homeDir}/${repoName}"
      fi

      echo "[setup] Building with colcon…"
      cd "${wsDir}"
      colcon build
      echo "[setup] Done."
    '';
  };

  # 2 Runtime: run your launch file; temporarily disable nounset when sourcing
  systemd.services.polyflow-webrtc = {
    description = "Run Polyflow WebRTC launch with ros2 launch";
    wantedBy = [ "multi-user.target" ];
    after    = [ "polyflow-setup.service" "network-online.target" ];
    wants    = [ "polyflow-setup.service" "network-online.target" ];

    # Make sure ros2 and ros2launch are on PATH for this unit
    path = with ros-pkgs.rosPackages.humble; [ ros2cli ros2launch launch launch-ros ros-base ];

    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    serviceConfig = {
      Restart      = "always";
      RestartSec   = "3s";
      User         = user;
      Group        = "users";
      WorkingDirectory = wsDir;
      StateDirectory   = "polyflow";
      StandardOutput   = "journal";
      StandardError    = "journal";
      ExecStart       = webrtcLauncher;
    };
  };
}
