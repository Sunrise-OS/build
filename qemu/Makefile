# Host clang + ld64.lld: static arm64 Mach-O images for bootxnu.
SYSROOT ?= $(CURDIR)/../../sysroot/arm64-apple-darwin
CLANG ?= clang
LFLAGS = -fuse-ld=lld -nostdlib -Wl,-e,_start
CFLAGS = -target arm64-apple-macos14.0 -ffreestanding -fno-builtin \
	-mstrict-align -mgeneral-regs-only -fno-stack-protector \
	-fno-PIC -O2 -Wall

OUT := out
AFDT := $(OUT)/afdt.bin

.PHONY: all clean

all: $(AFDT)

$(OUT):
	mkdir -p $(OUT)

$(AFDT): $(INIT) mkafdt.py
	python3 mkafdt.py -o $@ --ramdisk $(INIT) --ramdisk-phys 0x48000000

clean:
	rm -rf $(OUT)
