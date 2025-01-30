#!/bin/bash

set -e
set -x

if [ ! -d "./emsdk" ]; then
  git clone https://github.com/emscripten-core/emsdk.git --branch 1.39.20
  ./emsdk/emsdk install 1.39.20-fastcomp
  ./emsdk/emsdk activate 1.39.20-fastcomp
fi

source ./emsdk/emsdk_env.sh >/dev/null 2>&1
source ./.venv/bin/activate >/dev/null 2>&1

mkdir -p out build
if [ ! -f "build/vm.tar.gz" ]; then
  wget "https://bellard.org/tinyemu/diskimage-linux-riscv-2018-09-23.tar.gz" -O build/vm.tar.gz
fi
if [ ! -d "build/vm" ]; then
  tar -xf build/vm.tar.gz -C build
  mv build/diskimage* build/vm
fi

if [ "$1" = "clean" ]; then
  emmake make -C tinyemu/ -f Makefile.pdfjs clean
fi
emmake make -C tinyemu/ -f Makefile.pdfjs -j$(nproc --all)


if [ ! -f "build/pako.min.js" ]; then
  wget "https://cdn.jsdelivr.net/npm/pako@2.1.0/dist/pako.min.js" -O "build/pako.min.js"
fi

if [ ! -f "build/build_files" ]; then
  gcc tinyemu/build_filelist.c tinyemu/fs_utils.c tinyemu/cutils.c -o build/build_files
fi

get_alpine_rootfs() {
  wget https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/riscv64/latest-releases.yaml -O build/alpine-releases.yaml
  download_filename="$(grep "alpine-minirootfs-" build/alpine-releases.yaml | head -n1 | awk '{print $NF}')"
  download_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/riscv64/$download_filename"
  wget "$download_url" -O "build/$download_filename"
  mkdir -p "build/alpine"
  tar -xf "build/$download_filename" -C "build/alpine"

  #install base packages
  echo "nameserver 1.1.1.1" > "build/alpine/etc/resolv.conf"
  sudo chroot "build/alpine" apk add --no-cache agetty fastfetch nano htop

  #set up autologin
  echo "tty1::respawn:/sbin/agetty --autologin root tty0 linux" > "build/alpine/etc/inittab"
  echo "#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
hostname -F /etc/hostname
echo 'VM boot complete' > /dev/hvc0
fastfetch -l small" > "build/alpine/root/.profile"
  chmod +x "build/alpine/root/.profile"

  #set hostname and motd
  echo "linuxpdf" > "build/alpine/etc/hostname"
  echo -n "" > "build/alpine/etc/motd"

  #compile demos
  mkdir -p build/alpine/root/demos/
  git clone "https://github.com/kevinboone/fblife" build/alpine/root/demos/fblife
  echo '#!/bin/sh
set -e
set +x
apk add --no-cache gcc make musl-dev linux-headers

cd /root/demos/fblife
echo -e "#include <stdint.h>\n$(cat src/defs.h)" > src/defs.h
make
mv fblife /root/

cd /
apk del gcc make musl-dev linux-headers
rm -rf /root/demos
' > build/alpine/tmp/setup.sh
  chmod +x build/alpine/tmp/setup.sh
  sudo chroot "build/alpine" /bin/sh /tmp/setup.sh
}

#use a 9pfs mount for the root - more efficient
build_files() {
  if [ ! -d "build/alpine" ]; then
    get_alpine_rootfs
  fi
  if [ ! -d "build/files" ]; then
    mkdir -p build/files/root
    sudo build/build_files build/alpine/ build/files/root
  fi 
}

#use a block device for the root
build_disk() {
  if [ ! -d "build/files/disk" ]; then
    mkdir -p build/files/disk
    cp build/vm/root-riscv64.bin build/files/disk/root.bin

    block_size="256"
    (
      cd build/files/disk
      split -b "${block_size}K" -d -a 9 --additional-suffix=".bin" root.bin "blk"
      rm root.bin
    )
    num_blocks="$(find build/files/disk/ -name 'blk*.bin' | wc -l)"
    echo "
      {
        block_size: $block_size,
        n_block: $num_blocks,
      }
    " > build/files/disk/info.txt
  fi
}

build_files
cp vm.cfg build/vm/bbl64.bin build/vm/kernel-riscv64.bin build/files

python3 embed_files.py file_template.js build/files/ build/files.js
cat build/pako.min.js build/files.js pdflinux.js tinyemu/js/riscvemu64.js > out/compiled.js

python3 gen_pdf.py out/compiled.js out/linux.pdf
cp web/* out