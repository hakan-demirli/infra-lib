{
  fetchFromGitHub,
  kernel,
  lib,
  stdenv,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "ami";
  version = "1.8.0";

  src = fetchFromGitHub {
    owner = "Xilinx";
    repo = "AVED";
    rev = "amd_v80_gen5x8_23.2_exdes_1_20231204";
    hash = "sha256-0H7vDhM38neRSgXeYh14SIdtyyuo+zXPLxYBcHprIGo=";
  };

  sourceRoot = "${finalAttrs.src.name}/sw/AMI";

  nativeBuildInputs = kernel.moduleBuildDependencies;

  postPatch = ''
    patch -d driver -p0 < ${./patches/ami-23.2-Makefile.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-aer-reporting.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-ami_amc_control.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-background-workers.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-ami_cdev.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-ami_sensor.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-ami_sysfs.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-ami_hwmon.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-ami_program.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-ami_pcie.patch}
    patch -d driver -p0 < ${./patches/ami-23.2-linux-7.2.patch}
    patch -p0 < ${./patches/ami-23.2-api-Makefile.patch}
    patch -p0 < ${./patches/ami-23.2-app-Makefile.patch}
    patch -d app -p0 < ${./patches/ami-23.2-cmd_cfgmem_program.patch}
  '';

  buildPhase = ''
    runHook preBuild
    pushd driver
    make KERNEL_DIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build
    popd
    pushd api
    make
    popd
    pushd app
    make
    popd
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0444 driver/ami.ko $out/lib/modules/${kernel.modDirVersion}/extra/ami.ko
    install -Dm0755 app/build/ami_tool $out/bin/ami_tool
    install -Dm0644 api/build/libami.a $out/lib/libami.a
    install -d $out/include/ami
    install -m0644 api/include/*.h $out/include/ami/
    runHook postInstall
  '';

  dontStrip = true;
  enableParallelBuilding = true;

  meta = {
    description = "AVED Management Interface 1.8 for AMD Alveo V80";
    homepage = "https://github.com/Xilinx/AVED";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
})
