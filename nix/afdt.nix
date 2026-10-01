{
  lib,
  runCommand,
  python3,
  repo,
  diskRoot ? false,
  bootArgs ? "rd=md0 -v serial=3 debug=0x14e keepsyms=1 serial-device-name=uart0",
}:
runCommand "xnu-afdt" { nativeBuildInputs = [ python3 ]; } ''
  mkdir -p $out
  python3 ${repo}/qemu/mkafdt.py --output $out/AFDT ${
    if diskRoot then "--no-ramdisk" else "--ramdisk-size 4096"
  } --boot-args ${lib.escapeShellArg bootArgs}
''
