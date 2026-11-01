{
  id = "printer";
  network = "lan";
  ipv4 = "192.168.2.30";
  access.users = [
    {
      user = "former";
      ports = [ 631 ];
    }
  ];
}
