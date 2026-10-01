{ runCommand, dosfstools, mtools, pid1 }:
runCommand "xnu-fat-rootfs" {
  nativeBuildInputs = [ dosfstools mtools ];
} ''
  mkdir -p $out
  truncate -s 256M $out/rootfs.img
  # The image is > 65525 clusters; force FAT32 (small EFI helper images can
  # be misidentified as FAT16 by XNU's cluster-count based detector).
  mkfs.fat --invariant -F 32 -i 584e5531 -n XNUROOT $out/rootfs.img
  export MTOOLS_SKIP_CHECK=1
  mmd -i $out/rootfs.img ::/sbin ::/dev
  mcopy -m -i $out/rootfs.img ${pid1}/sbin/launchd ::/sbin/launchd
  fsck.fat -n $out/rootfs.img
  mcopy -i $out/rootfs.img ::/sbin/launchd roundtrip
  cmp ${pid1}/sbin/launchd roundtrip
''
