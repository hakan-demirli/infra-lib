{
  id = "desk";
  network = "lan";
  ipv4 = "192.168.2.20";
  access = {
    teams = [
      {
        team = "guests";
        ports = [ 22 ];
      }
      {
        team = "alumni";
        ports = [ 80 ];
      }
    ];
    users = [
      {
        user = "former";
        ports = [ 8080 ];
      }
    ];
  };
}
