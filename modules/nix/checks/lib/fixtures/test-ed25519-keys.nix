{ pkgs }:
{
  # Publicly committed test-only keys. Never use them outside the test suite.
  admin = {
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFrPXA+SHurksC+EeyI5iAWa7dHLGqy0TfHgUw3lKYvL admin-user@test-only";
    privateKey = pkgs.writeText "admin-user-test-only-ed25519-key" ''
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
      QyNTUxOQAAACBaz1wPkh7q5LAvhHsiOYgFmu3RyxqstE3x4FMN5SmLywAAAJhQn8U7UJ/F
      OwAAAAtzc2gtZWQyNTUxOQAAACBaz1wPkh7q5LAvhHsiOYgFmu3RyxqstE3x4FMN5SmLyw
      AAAEC3WcjCeOLhVxn8A+zJB3M8q+zCaxnSpxQUoVU1OdGB61rPXA+SHurksC+EeyI5iAWa
      7dHLGqy0TfHgUw3lKYvLAAAAEGFjY2Vzcy10aWVyLXRlc3QBAgMEBQ==
      -----END OPENSSH PRIVATE KEY-----
    '';
  };

  standard = {
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIv7bskR2JjJY/TePu2PdTkESrb2OikpNqFFaCxTBUcL standard-user@test-only";
    privateKey = pkgs.writeText "standard-user-test-only-ed25519-key" ''
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
      QyNTUxOQAAACCL+27JEdiYyWP03j7tj3U5BEq29jopKTahRWgsUwVHCwAAAKB3eDmKd3g5
      igAAAAtzc2gtZWQyNTUxOQAAACCL+27JEdiYyWP03j7tj3U5BEq29jopKTahRWgsUwVHCw
      AAAEDue7j6uSfthJIoMoYc/O0jfBEd2gNwgpUAHbrQkOBw6Iv7bskR2JjJY/TePu2PdTkE
      Srb2OikpNqFFaCxTBUcLAAAAF3N0YW5kYXJkLXVzZXJAdGVzdC1vbmx5AQIDBAUG
      -----END OPENSSH PRIVATE KEY-----
    '';
  };
}
