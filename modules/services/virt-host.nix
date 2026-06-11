{
  lib,
  pkgs,
  host ? null,
  cluster ? null,
  ...
}:
let
  virt = if host == null then null else (host.virt or null);
  active = virt != null && virt.enable;

  guests =
    if cluster == null || !active then
      [ ]
    else
      lib.filter (
        g:
        (g.location.kind or null) == "kvm-guest"
        && (g.location.host or null) == host.id
        && ((g.virt.role or "host") == "guest")
        && !(lib.elem g.state [
          "planned"
          "retired"
          "decommissioned"
        ])
      ) (lib.attrValues cluster.hosts);

  primaryUserOf =
    g:
    let
      owner = g.ownership.owner or null;
      ownerUser = if owner == null || cluster == null then null else (cluster.users.${owner} or null);
    in
    ownerUser;

  mkDomainXml =
    g:
    let
      diskPath = "${virt.pool_path}/${g.id}.qcow2";
      seedPath = "${virt.pool_path}/${g.id}-seed.iso";
      cpus = toString (g.virt.cpus or 2);
      ramKb = toString (1048576 * (g.virt.ram_gb or 2));
    in
    pkgs.writeText "${g.id}.xml" ''
      <domain type='kvm'>
        <name>${g.id}</name>
        <memory unit='KiB'>${ramKb}</memory>
        <currentMemory unit='KiB'>${ramKb}</currentMemory>
        <vcpu placement='static'>${cpus}</vcpu>
        <os>
          <type arch='x86_64' machine='q35'>hvm</type>
          <loader readonly='yes' secure='no' type='pflash'>
            ${pkgs.OVMFFull.fd}/FV/OVMF_CODE.fd
          </loader>
          <boot dev='hd'/>
        </os>
        <features>
          <acpi/>
          <apic/>
        </features>
        <cpu mode='host-passthrough' check='none' migratable='on'/>
        <clock offset='utc'/>
        <on_poweroff>destroy</on_poweroff>
        <on_reboot>restart</on_reboot>
        <on_crash>destroy</on_crash>
        <devices>
          <emulator>${pkgs.qemu_kvm}/bin/qemu-system-x86_64</emulator>
          <disk type='file' device='disk'>
            <driver name='qemu' type='qcow2'/>
            <source file='${diskPath}'/>
            <target dev='vda' bus='virtio'/>
          </disk>
          <disk type='file' device='cdrom'>
            <driver name='qemu' type='raw'/>
            <source file='${seedPath}'/>
            <target dev='sda' bus='sata'/>
            <readonly/>
          </disk>
          <interface type='bridge'>
            <source bridge='${virt.bridge}'/>
            <model type='virtio'/>
          </interface>
          <console type='pty'>
            <target type='serial' port='0'/>
          </console>
          <serial type='pty'>
            <target type='isa-serial' port='0'>
              <model name='isa-serial'/>
            </target>
          </serial>
        </devices>
      </domain>
    '';

  mkUserData =
    g:
    let
      u = primaryUserOf g;
      uname = if u == null then "ubuntu" else u.system_account.username;
      sshKeys = if u == null then [ ] else u.keys.ssh;
    in
    pkgs.writeText "${g.id}-user-data" ''
      hostname: ${g.id}
      manage_etc_hosts: true
      users:
        - name: ${uname}
          sudo: ALL=(ALL) NOPASSWD:ALL
          shell: /bin/bash
          ssh_authorized_keys:
      ${lib.concatMapStringsSep "\n" (k: "      - ${k}") sshKeys}
      package_update: true
      packages:
        - openssh-server
        - tailscale
        - ceph-common
      runcmd:
        - systemctl enable --now ssh
    '';

  mkMetaData =
    g:
    pkgs.writeText "${g.id}-meta-data" ''
      instance-id: ${g.id}
      local-hostname: ${g.id}
    '';

  mkGuestProvisionScript = g: ''
    pool="${virt.pool_path}"
    disk="$pool/${g.id}.qcow2"
    seed="$pool/${g.id}-seed.iso"
    baseImg="$pool/base/${g.virt.image or "_missing"}.qcow2"

    if [ ! -f "$disk" ]; then
      ${pkgs.qemu_kvm}/bin/qemu-img create -f qcow2 \
        -F qcow2 -b "$baseImg" \
        "$disk" ${toString (g.virt.disk_gb or 20)}G
      chown root:libvirtd "$disk" && chmod 0660 "$disk"
    fi

    if [ ! -f "$seed" ]; then
      tmpdir=$(${pkgs.coreutils}/bin/mktemp -d)
      cp "${mkUserData g}" "$tmpdir/user-data"
      cp "${mkMetaData g}" "$tmpdir/meta-data"
      ${pkgs.cdrkit}/bin/genisoimage \
        -output "$seed" \
        -volid cidata -joliet -rock \
        "$tmpdir/user-data" "$tmpdir/meta-data"
      rm -rf "$tmpdir"
      chown root:libvirtd "$seed" && chmod 0660 "$seed"
    fi

    if ! ${pkgs.libvirt}/bin/virsh dominfo ${g.id} >/dev/null 2>&1; then
      ${pkgs.libvirt}/bin/virsh define ${mkDomainXml g}
      ${pkgs.libvirt}/bin/virsh autostart ${g.id}
    fi
  '';
in
{
  config = lib.mkIf active {
    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = false;
        swtpm.enable = true;
        ovmf = {
          enable = true;
          packages = [ pkgs.OVMFFull.fd ];
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d ${virt.pool_path} 0775 root libvirtd -"
    ];

    systemd.services."virt-host-base-images" =
      let
        fetchScripts = lib.mapAttrsToList (
          name: img:
          let
            fetched = pkgs.fetchurl {
              inherit (img) url;
              inherit (img) sha256;
            };
            destBase = "${virt.pool_path}/base";
            dest = "${destBase}/${name}.${img.format}";
          in
          ''
            mkdir -p "${destBase}"
            if [ ! -f "${dest}" ]; then
              cp "${fetched}" "${dest}"
              chmod 0644 "${dest}"
              chown root:libvirtd "${dest}"
            fi
          ''
        ) virt.images;
      in
      lib.mkIf (virt.images != { }) {
        description = "Fetch base cloud images into libvirt storage pool";
        wantedBy = [ "multi-user.target" ];
        before = [ "libvirtd.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = lib.concatStringsSep "\n" fetchScripts;
      };

    environment.systemPackages = with pkgs; [
      libvirt
      virt-manager
      virt-viewer
      cdrkit
      qemu_kvm
    ];

    systemd.services."virt-host-guest-provisioning" = lib.mkIf (guests != [ ]) {
      description = "Materialise libvirt guest definitions for declared VMs";
      wantedBy = [ "multi-user.target" ];
      after = [
        "libvirtd.service"
        "virt-host-base-images.service"
      ];
      requires = [ "libvirtd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatMapStringsSep "\n\n" mkGuestProvisionScript guests;
    };

  };
}
