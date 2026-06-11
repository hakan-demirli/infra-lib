{
  stdenv,
  fetchFromGitHub,
  lib,
}:
stdenv.mkDerivation {
  pname = "sddm-sugar-dark";
  version = "0-unstable-2021-08-16";

  src = fetchFromGitHub {
    owner = "MarianArlt";
    repo = "sddm-sugar-dark";
    rev = "ceb2c455663429be03ba62d9f898c571650ef7fe";
    sha256 = "0153z1kylbhc9d12nxy9vpn0spxgrhgy36wy37pk6ysq7akaqlvy";
  };

  installPhase = ''
    mkdir -p $out/share/sddm/themes/sugar-dark
    cp -R ./* $out/share/sddm/themes/sugar-dark/
  '';

  meta = with lib; {
    description = "Sugar Dark SDDM theme";
    homepage = "https://github.com/MarianArlt/sddm-sugar-dark";
    license = licenses.gpl3Plus;
    platforms = platforms.linux;
  };
}
