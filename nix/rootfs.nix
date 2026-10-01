{ runCommand, mkapfs, apfsck, hadris-apfs-cli, python3, repo }:
runCommand "xnu-apfs-rootfs-empty" {
  nativeBuildInputs = [ mkapfs apfsck hadris-apfs-cli python3 ];
} ''
  mkdir -p "$out"
  export SOURCE_DATE_EPOCH=1
  truncate -s 256M "$out/rootfs.img"
  mkapfs -s -z -L XNU \
    -U 6bf57e62-d9bd-4fba-9189-cf1b9d613f19 \
    -u f3eb5f9b-9b58-44e6-8bf5-ff831ba8be0d "$out/rootfs.img"
  python3 ${repo}/rootfs/test-image.py "$out/rootfs.img" | tee "$out/validation.txt"
''
