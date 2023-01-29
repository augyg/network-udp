{ mkDerivation, base, bytestring, containers, iproute, lib, network
}:
mkDerivation {
  pname = "network-udp";
  version = "0.0.0";
  src = ./.;
  libraryHaskellDepends = [
    base bytestring containers iproute network
  ];
  description = "UDP library";
  license = lib.licenses.bsd3;
}
