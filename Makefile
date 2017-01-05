# Configuration
ARCH?=x86_64

# Automatic variables
ROOT=$(PWD)
export RUST_TARGET_PATH=$(ROOT)/targets
export CC=$(ROOT)/libc-artifacts/gcc.sh
export CFLAGS=-fno-stack-protector -U_FORTIFY_SOURCE

# Kernel variables
KTARGET=$(ARCH)-unknown-none
KBUILD=build/kernel
KRUSTC=./krustc.sh
KRUSTDOC=./krustdoc.sh
KCARGO=RUSTC="$(KRUSTC)" RUSTDOC="$(KRUSTDOC)" cargo
KCARGOFLAGS=--target $(KTARGET) --release -- -C soft-float

# Userspace variables
export TARGET=$(ARCH)-unknown-redox
BUILD=build/userspace
RUSTC=./rustc.sh
RUSTDOC=./rustdoc.sh
CARGO=RUSTC="$(RUSTC)" RUSTDOC="$(RUSTDOC)" cargo
CARGOFLAGS=--target $(TARGET) --release -- -C codegen-units=`nproc`

# Default targets
.PHONY: all live iso clean doc ref test update pull qemu bochs drivers schemes binutils coreutils extrautils netutils userutils wireshark FORCE

all: build/harddrive.bin

live: build/livedisk.bin

iso: build/livedisk.iso

FORCE:

clean:
	cargo clean
	cargo clean --manifest-path rust/src/libcollections/Cargo.toml
	cargo clean --manifest-path rust/src/libstd/Cargo.toml
	-$(FUMOUNT) build/filesystem/ || true
	rm -rf initfs/bin
	rm -rf filesystem/bin filesystem/sbin filesystem/ui/bin
	rm -rf build

doc: \
	doc-kernel \
	doc-std

#FORCE to let cargo decide if docs need updating
doc-kernel: $(KBUILD)/libkernel.a FORCE
	$(KCARGO) doc --target $(KTARGET).json --manifest-path kernel/Cargo.toml

doc-std: $(BUILD)/libstd.rlib FORCE
	$(CARGO) doc --target $(TARGET).json --manifest-path rust/src/libstd/Cargo.toml

ref: FORCE
	rm -rf filesystem/ref/
	mkdir -p filesystem/ref/
	cargo run --manifest-path crates/docgen/Cargo.toml -- programs/binutils/src/bin/ filesystem/ref/
	cargo run --manifest-path crates/docgen/Cargo.toml -- programs/coreutils/src/bin/ filesystem/ref/
	cargo run --manifest-path crates/docgen/Cargo.toml -- programs/extrautils/src/bin/ filesystem/ref/
	cargo run --manifest-path crates/docgen/Cargo.toml -- programs/netutils/src/ filesystem/ref/

update:
	cargo update

pull:
	git pull --rebase --recurse-submodules
	git submodule sync
	git submodule update --recursive --init
	git clean -X -f -d
	make clean
	make update

# Emulation
QEMU=SDL_VIDEO_X11_DGAMOUSE=0 qemu-system-$(ARCH)
QEMUFLAGS=-serial mon:stdio -d cpu_reset -d guest_errors
ifeq ($(ARCH),arm)
	QEMUFLAGS+=-cpu arm1176 -machine integratorcp
	QEMUFLAGS+=-nographic

	export CC=$(ARCH)-none-eabi-gcc
	export LD=$(ARCH)-none-eabi-ld

%.list: %
	$(ARCH)-none-eabi-objdump -C -D $< > $@

build/harddrive.bin: $(KBUILD)/kernel
	cp $< $@

qemu: build/harddrive.bin
	$(QEMU) $(QEMUFLAGS) -kernel $<
else
	QEMUFLAGS+=-smp 4 -m 1024
	ifeq ($(iommu),yes)
		QEMUFLAGS+=-machine q35,iommu=on
	else
		QEMUFLAGS+=-machine q35
	endif
	ifeq ($(net),no)
		QEMUFLAGS+=-net none
	else
		QEMUFLAGS+=-net nic,model=e1000 -net user -net dump,file=build/network.pcap
		ifeq ($(net),redir)
			QEMUFLAGS+=-redir tcp:8023::8023 -redir tcp:8080::8080
		endif
	endif
	ifeq ($(vga),no)
		QEMUFLAGS+=-nographic -vga none
	endif
	#,int,pcall
	#-device intel-iommu

	UNAME := $(shell uname)
	ifeq ($(UNAME),Darwin)
		ECHO=/bin/echo
		FUMOUNT=sudo umount
		export LD=$(ARCH)-elf-ld
		export LDFLAGS=--gc-sections
		export STRIP=$(ARCH)-elf-strip
		VB_AUDIO=coreaudio
		VBM="/Applications/VirtualBox.app/Contents/MacOS/VBoxManage"
	else
		ECHO=echo
		FUMOUNT=fusermount -u
		export LD=ld
		export LDFLAGS=--gc-sections
		export STRIP=strip
		ifneq ($(kvm),no)
			QEMUFLAGS+=-enable-kvm -cpu host
		endif
		VB_AUDIO="pulse"
		VBM=VBoxManage
	endif

%.list: %
	objdump -C -M intel -D $< > $@

build/harddrive.bin: $(KBUILD)/kernel bootloader/$(ARCH)/** build/filesystem.bin
	nasm -f bin -o $@ -D ARCH_$(ARCH) -ibootloader/$(ARCH)/ bootloader/$(ARCH)/harddrive.asm

build/livedisk.bin: $(KBUILD)/kernel_live bootloader/$(ARCH)/**
	nasm -f bin -o $@ -D ARCH_$(ARCH) -ibootloader/$(ARCH)/ bootloader/$(ARCH)/livedisk.asm

build/%.bin.gz: build/%.bin
	gzip -k -f $<

build/livedisk.iso: build/livedisk.bin.gz
	rm -rf build/iso/
	mkdir -p build/iso/
	cp -RL isolinux build/iso/
	cp $< build/iso/livedisk.gz
	genisoimage -o $@ -b isolinux/isolinux.bin -c isolinux/boot.cat \
					-no-emul-boot -boot-load-size 4 -boot-info-table \
					build/iso/
	isohybrid $@

qemu: build/harddrive.bin
	$(QEMU) $(QEMUFLAGS) -drive file=$<,format=raw

qemu_extra: build/harddrive.bin
	if [ ! -e build/extra.bin ]; then dd if=/dev/zero of=build/extra.bin bs=1048576 count=1024; fi
	$(QEMU) $(QEMUFLAGS) -drive file=$<,format=raw -drive file=build/extra.bin,format=raw

qemu_no_build:
	$(QEMU) $(QEMUFLAGS) -drive file=build/harddrive.bin,format=raw

qemu_live: build/livedisk.bin
	$(QEMU) $(QEMUFLAGS) -device usb-ehci,id=flash_bus -drive id=flash_drive,file=$<,format=raw,if=none -device usb-storage,drive=flash_drive,bus=flash_bus.0

qemu_live_no_build:
	$(QEMU) $(QEMUFLAGS) -device usb-ehci,id=flash_bus -drive id=flash_drive,file=build/livedisk.bin,format=raw,if=none -device usb-storage,drive=flash_drive,bus=flash_bus.0

qemu_iso: build/livedisk.iso
	$(QEMU) $(QEMUFLAGS) -boot d -cdrom $<

qemu_iso_no_build:
		$(QEMU) $(QEMUFLAGS) -boot d -cdrom build/livedisk.iso

endif

bochs: build/harddrive.bin
	bochs -f bochs.$(ARCH)

virtualbox: build/harddrive.bin
	echo "Delete VM"
	-$(VBM) unregistervm Redox --delete; \
	if [ $$? -ne 0 ]; \
	then \
		if [ -d "$$HOME/VirtualBox VMs/Redox" ]; \
		then \
			echo "Redox directory exists, deleting..."; \
			$(RM) -rf "$$HOME/VirtualBox VMs/Redox"; \
		fi \
	fi
	echo "Delete Disk"
	-$(RM) harddrive.vdi
	echo "Create VM"
	$(VBM) createvm --name Redox --register
	echo "Set Configuration"
	$(VBM) modifyvm Redox --memory 1024
	$(VBM) modifyvm Redox --vram 16
	if [ "$(net)" != "no" ]; \
	then \
		$(VBM) modifyvm Redox --nic1 nat; \
		$(VBM) modifyvm Redox --nictype1 82540EM; \
		$(VBM) modifyvm Redox --cableconnected1 on; \
		$(VBM) modifyvm Redox --nictrace1 on; \
		$(VBM) modifyvm Redox --nictracefile1 build/network.pcap; \
	fi
	$(VBM) modifyvm Redox --uart1 0x3F8 4
	$(VBM) modifyvm Redox --uartmode1 file build/serial.log
	$(VBM) modifyvm Redox --usb off # on
	$(VBM) modifyvm Redox --keyboard ps2
	$(VBM) modifyvm Redox --mouse ps2
	$(VBM) modifyvm Redox --audio $(VB_AUDIO)
	$(VBM) modifyvm Redox --audiocontroller ac97
	$(VBM) modifyvm Redox --nestedpaging off
	echo "Create Disk"
	$(VBM) convertfromraw $< build/harddrive.vdi
	echo "Attach Disk"
	$(VBM) storagectl Redox --name ATA --add sata --controller IntelAHCI --bootable on --portcount 1
	$(VBM) storageattach Redox --storagectl ATA --port 0 --device 0 --type hdd --medium build/harddrive.vdi
	echo "Run VM"
	$(VBM) startvm Redox

# Kernel recipes
$(KBUILD)/libcollections.rlib: rust/src/libcollections/Cargo.toml rust/src/libcollections/**
	mkdir -p $(KBUILD)
	$(KCARGO) rustc --verbose --manifest-path $< $(KCARGOFLAGS) -o $@
	cp rust/src/target/$(KTARGET)/release/deps/*.rlib $(KBUILD)

$(KBUILD)/libkernel.a: kernel/Cargo.toml kernel/arch/** kernel/src/** $(KBUILD)/libcollections.rlib $(BUILD)/initfs.rs
	$(KCARGO) rustc --manifest-path $< --lib $(KCARGOFLAGS) -C lto --emit obj=$@

$(KBUILD)/libkernel_live.a: kernel/Cargo.toml kernel/arch/** kernel/src/** $(KBUILD)/libcollections.rlib $(BUILD)/initfs.rs build/filesystem.bin
	$(KCARGO) rustc --manifest-path $< --lib --features live $(KCARGOFLAGS) -C lto --emit obj=$@

$(KBUILD)/kernel: $(KBUILD)/libkernel.a
	$(LD) $(LDFLAGS) -z max-page-size=0x1000 -T kernel/arch/$(ARCH)/src/linker.ld -o $@ $<

$(KBUILD)/kernel_live: $(KBUILD)/libkernel_live.a
	$(LD) $(LDFLAGS) -z max-page-size=0x1000 -T kernel/arch/$(ARCH)/src/linker.ld -o $@ $<

# Userspace recipes
$(BUILD)/libstd.rlib: rust/src/libstd/Cargo.toml rust/src/libstd/**
	mkdir -p $(BUILD)
	$(CARGO) rustc --verbose --manifest-path $< --features "panic-unwind" $(CARGOFLAGS) -L native=libc-artifacts/usr/lib -o $@
	cp rust/src/target/$(TARGET)/release/deps/*.rlib $(BUILD)

$(BUILD)/libtest.rlib: rust/src/libtest/Cargo.toml rust/src/libtest/** $(BUILD)/libstd.rlib
	mkdir -p $(BUILD)
	$(CARGO) rustc --verbose --manifest-path $< $(CARGOFLAGS) -L native=libc-artifacts/usr/lib -o $@
	cp rust/src/target/$(TARGET)/release/deps/*.rlib $(BUILD)

initfs/bin/%: drivers/%/Cargo.toml drivers/%/src/** $(BUILD)/libstd.rlib
	mkdir -p initfs/bin
	$(CARGO) rustc --manifest-path $< $(CARGOFLAGS) -o $@
	$(STRIP) $@

initfs/bin/%: programs/%/Cargo.toml programs/%/src/** $(BUILD)/libstd.rlib
	mkdir -p initfs/bin
	$(CARGO) rustc --manifest-path $< $(CARGOFLAGS) -o $@
	$(STRIP) $@

initfs/bin/%: schemes/%/Cargo.toml schemes/%/src/** $(BUILD)/libstd.rlib
	mkdir -p initfs/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

$(BUILD)/initfs.rs: \
		initfs/bin/init \
		initfs/bin/ahcid \
		initfs/bin/bgad \
		initfs/bin/pcid \
		initfs/bin/ps2d \
		initfs/bin/redoxfs \
		initfs/bin/vesad \
		initfs/etc/**
	echo 'use collections::BTreeMap;' > $@
	echo 'pub fn gen() -> BTreeMap<&'"'"'static [u8], (&'"'"'static [u8], bool)> {' >> $@
	echo '    let mut files: BTreeMap<&'"'"'static [u8], (&'"'"'static [u8], bool)> = BTreeMap::new();' >> $@
	for folder in `find initfs -type d | sort`; do \
		name=$$(echo $$folder | sed 's/initfs//' | cut -d '/' -f2-) ; \
		$(ECHO) -n '    files.insert(b"'$$name'", (b"' >> $@ ; \
		ls -1 $$folder | sort | awk 'NR > 1 {printf("\\n")} {printf("%s", $$0)}' >> $@ ; \
		echo '", true));' >> $@ ; \
	done
	find initfs -type f -o -type l | cut -d '/' -f2- | sort | awk '{printf("    files.insert(b\"%s\", (include_bytes!(\"../../initfs/%s\"), false));\n", $$0, $$0)}' >> $@
	echo '    files' >> $@
	echo '}' >> $@

filesystem/sbin/%: drivers/%/Cargo.toml drivers/%/src/** $(BUILD)/libstd.rlib
	mkdir -p filesystem/sbin
	$(CARGO) rustc --manifest-path $< $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/bin/%: programs/%/Cargo.toml programs/%/src/** $(BUILD)/libstd.rlib
	mkdir -p filesystem/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

# Example of compiling tests - still TODO
filesystem/test/%: programs/%/Cargo.toml programs/%/src/** $(BUILD)/libstd.rlib $(BUILD)/libtest.rlib
	mkdir -p filesystem/test
	$(CARGO) test --no-run --manifest-path $< $(CARGOFLAGS)
	cp programs/$*/target/$(TARGET)/release/deps/$*-* $@

filesystem/bin/sh: filesystem/bin/ion
	cp $< $@

filesystem/bin/%: programs/binutils/Cargo.toml programs/binutils/src/bin/%.rs $(BUILD)/libstd.rlib
	mkdir -p filesystem/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/bin/%: programs/coreutils/Cargo.toml programs/coreutils/src/bin/%.rs $(BUILD)/libstd.rlib
	mkdir -p filesystem/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/bin/%: programs/extrautils/Cargo.toml programs/extrautils/src/bin/%.rs $(BUILD)/libstd.rlib
	mkdir -p filesystem/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/bin/%: programs/games/Cargo.toml programs/games/src/%/**.rs $(BUILD)/libstd.rlib
	mkdir -p filesystem/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/bin/%: programs/netutils/Cargo.toml programs/netutils/src/%/**.rs $(BUILD)/libstd.rlib
	mkdir -p filesystem/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/ui/bin/%: programs/orbutils/Cargo.toml programs/orbutils/src/%/**.rs $(BUILD)/libstd.rlib
	mkdir -p filesystem/ui/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/bin/%: programs/pkgutils/Cargo.toml programs/pkgutils/src/%/**.rs $(BUILD)/libstd.rlib
	mkdir -p filesystem/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/bin/%: programs/userutils/Cargo.toml programs/userutils/src/bin/%.rs $(BUILD)/libstd.rlib
	mkdir -p filesystem/bin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/sbin/%: schemes/%/Cargo.toml schemes/%/src/** $(BUILD)/libstd.rlib
	mkdir -p filesystem/sbin
	$(CARGO) rustc --manifest-path $< --bin $* $(CARGOFLAGS) -o $@
	$(STRIP) $@

filesystem/sbin/redoxfs-mkfs: schemes/redoxfs/Cargo.toml schemes/redoxfs/src/** $(BUILD)/libstd.rlib
	mkdir -p filesystem/bin
	$(CARGO) rustc --manifest-path $< --bin redoxfs-mkfs $(CARGOFLAGS) -o $@
	$(STRIP) $@

drivers: \
	filesystem/sbin/pcid \
	filesystem/sbin/e1000d \
	filesystem/sbin/rtl8168d

binutils: \
	filesystem/bin/hex \
	filesystem/bin/hexdump \
	filesystem/bin/strings

coreutils: \
	filesystem/bin/basename \
	filesystem/bin/cat \
	filesystem/bin/chmod \
	filesystem/bin/clear \
	filesystem/bin/cp \
	filesystem/bin/cut \
	filesystem/bin/date \
	filesystem/bin/dd \
	filesystem/bin/df \
	filesystem/bin/du \
	filesystem/bin/echo \
	filesystem/bin/env \
	filesystem/bin/false \
	filesystem/bin/free \
	filesystem/bin/head \
	filesystem/bin/kill \
	filesystem/bin/ls \
	filesystem/bin/mkdir \
	filesystem/bin/mv \
	filesystem/bin/printenv \
	filesystem/bin/ps \
	filesystem/bin/pwd \
	filesystem/bin/realpath \
	filesystem/bin/reset \
	filesystem/bin/rmdir \
	filesystem/bin/rm \
	filesystem/bin/seq \
	filesystem/bin/sleep \
	filesystem/bin/sort \
	filesystem/bin/tail \
	filesystem/bin/tee \
	filesystem/bin/time \
	filesystem/bin/touch \
	filesystem/bin/true \
	filesystem/bin/wc \
	filesystem/bin/yes
	#filesystem/bin/shutdown filesystem/bin/test

extrautils: \
	filesystem/bin/calc \
	filesystem/bin/cksum \
	filesystem/bin/cur \
	filesystem/bin/grep \
	filesystem/bin/less \
	filesystem/bin/man \
	filesystem/bin/mdless \
	filesystem/bin/mtxt \
	filesystem/bin/rem \
	#filesystem/bin/dmesg filesystem/bin/info  filesystem/bin/watch

games: \
	filesystem/bin/ice \
	filesystem/bin/minesweeper \
	filesystem/bin/reblox \
	filesystem/bin/rusthello \
	filesystem/bin/snake

netutils: \
	filesystem/bin/dhcpd \
	filesystem/bin/dns \
	filesystem/bin/httpd \
	filesystem/bin/irc \
	filesystem/bin/nc \
	filesystem/bin/ntp \
	filesystem/bin/telnetd \
	filesystem/bin/wget

orbutils: \
	filesystem/ui/bin/browser \
	filesystem/ui/bin/calculator \
	filesystem/ui/bin/character_map \
	filesystem/ui/bin/editor \
	filesystem/ui/bin/file_manager \
	filesystem/ui/bin/launcher \
	filesystem/ui/bin/orblogin \
	filesystem/ui/bin/terminal \
	filesystem/ui/bin/viewer

pkgutils: \
	filesystem/bin/pkg

userutils: \
	filesystem/bin/getty \
	filesystem/bin/id \
	filesystem/bin/login \
	filesystem/bin/passwd \
	filesystem/bin/su \
	filesystem/bin/sudo

schemes: \
	filesystem/sbin/ethernetd \
	filesystem/sbin/ipd \
	filesystem/sbin/orbital \
	filesystem/sbin/ptyd \
	filesystem/sbin/randd \
	filesystem/sbin/redoxfs \
	filesystem/sbin/redoxfs-mkfs \
	filesystem/sbin/tcpd \
	filesystem/sbin/udpd

build/filesystem.bin: \
		drivers \
		coreutils \
		extrautils \
		games \
		netutils \
		orbutils \
		pkgutils \
		userutils \
		schemes \
		filesystem/bin/acid \
		filesystem/bin/contain \
		filesystem/bin/ion \
		filesystem/bin/sh \
		filesystem/bin/smith \
		filesystem/bin/tar
	-$(FUMOUNT) build/filesystem/ || true
	rm -rf $@ build/filesystem/
	dd if=/dev/zero of=$@ bs=1048576 count=64
	cargo run --manifest-path schemes/redoxfs/Cargo.toml --release --bin redoxfs-mkfs $@
	mkdir -p build/filesystem/
	cargo build --manifest-path schemes/redoxfs/Cargo.toml --release --bin redoxfs
	cargo run --manifest-path schemes/redoxfs/Cargo.toml --release --bin redoxfs -- $@ build/filesystem/
	sleep 2
	pgrep redoxfs
	cp -RL filesystem/* build/filesystem/
	chown -R 0:0 build/filesystem
	chown -R 1000:1000 build/filesystem/home/user
	chmod -R uog+rX build/filesystem
	chmod -R u+w build/filesystem
	chmod -R og-w build/filesystem
	chmod -R 755 build/filesystem/bin
	chmod -R u+rwX build/filesystem/root
	chmod -R og-rwx build/filesystem/root
	chmod -R u+rwX build/filesystem/home/user
	chmod -R og-rwx build/filesystem/home/user
	chmod +s build/filesystem/bin/passwd
	chmod +s build/filesystem/bin/su
	chmod +s build/filesystem/bin/sudo
	mkdir build/filesystem/tmp
	chmod 1777 build/filesystem/tmp
	sync
	-$(FUMOUNT) build/filesystem/ || true
	rm -rf build/filesystem/

mount: FORCE
	mkdir -p build/filesystem/
	cargo build --manifest-path schemes/redoxfs/Cargo.toml --release --bin redoxfs
	cargo run --manifest-path schemes/redoxfs/Cargo.toml --release --bin redoxfs -- build/harddrive.bin build/filesystem/
	sleep 2
	pgrep redoxfs

unmount: FORCE
	sync
	-$(FUMOUNT) build/filesystem/ || true
	rm -rf build/filesystem/

wireshark: FORCE
	wireshark build/network.pcap
