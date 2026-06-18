proot := source_dir()
qemu_ssh_port := "2222"
user := `whoami`
rep := '1'
ssd_id := 'c3:00.0'

help:
    just --list

sync-push remote rpath:
    git ls-files -z --recurse-submodules | rsync -avz --from0 --files-from=- {{proot}}/ {{remote}}:{{rpath}}/

sync-pull remote rpath:
    rsync -avz {{remote}}:{{rpath}}/compile_commands.json {{invocation_directory()}}/
    # rewrite remote paths so clangd can chdir to `directory` and resolve relative -I paths
    sed -i 's|{{rpath}}|{{invocation_directory()}}|g' {{invocation_directory()}}/compile_commands.json

gen-compile-commands remote rpath image="integrated_vmcache_tabby":
    just sync-push {{remote}} {{rpath}}
    ssh {{remote}} "cd {{rpath}} && nix develop --command bash -c 'cd osv && bear --output ../compile_commands.json -- ./scripts/build -j fs=ramfs image={{image}}'"
    just sync-pull {{remote}} {{rpath}}

ssh COMMAND="":
    @ ssh \
    -i {{proot}}/nix/keyfile \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentityAgent=/dev/null \
    -o LogLevel=ERROR \
    -F /dev/null \
    -p {{qemu_ssh_port}} \
    root@localhost -- "{{COMMAND}}"

linux_vm nb_cpu="1" size_mem="16384": (bind-ssd-vfio ssd_id) check_downgraded_link
    #!/usr/bin/env bash
    let "taskset_cores = {{nb_cpu}}-1"
    sudo taskset -c 0-$taskset_cores qemu-system-x86_64 \
        -cpu host \
        -smp {{nb_cpu}} \
        -enable-kvm \
        -m {{size_mem}} \
        -machine q35,accel=kvm,kernel-irqchip=split \
        -device intel-iommu,intremap=on,device-iotlb=on,caching-mode=on \
        -device virtio-serial \
        -fsdev local,id=home,path={{proot}},security_model=none \
        -device virtio-9p-pci,fsdev=home,mount_tag=home,disable-modern=on,disable-legacy=off \
        -fsdev local,id=scratch,path=/scratch/{{user}},security_model=none \
        -device virtio-9p-pci,fsdev=scratch,mount_tag=scratch,disable-modern=on,disable-legacy=off \
        -fsdev local,id=nixstore,path=/nix/store,security_model=none \
        -device virtio-9p-pci,fsdev=nixstore,mount_tag=nixstore,disable-modern=on,disable-legacy=off \
        -drive file={{proot}}/VMs/linux-image.qcow2 \
        -net nic,netdev=user.0,model=virtio \
        -netdev user,id=user.0,hostfwd=tcp:127.0.0.1:{{qemu_ssh_port}}-:22 \
        -nographic \
        -device vfio-pci,host={{ssd_id}}

linux-image-init:
    #!/usr/bin/env bash
    set -x
    set -e
    echo "Initializing disk for the VM"
    mkdir -p {{proot}}/VMs

    # build images fast
    overwrite() {
        install -D -m644 {{proot}}/VMs/ro/nixos.qcow2 {{proot}}/VMs/$1.qcow2
        qemu-img resize {{proot}}/VMs/$1.qcow2 +8g
    }

    nix build .#linux-image --out-link {{proot}}/VMs/ro
    overwrite linux-image

osv-image-init image="" app_objects="" extra_cxxflags="":
    #!/usr/bin/env bash
    cd {{proot}}/osv/
    _app_objects="{{app_objects}}"
    _app_libs=""
    if [[ -z "$_app_objects" ]]; then
        if [[ -f "benchmarks/{{image}}/{{image}}_app.cc" ]]; then
            # static-lib style: benchmark compiled separately, thin wrapper linked into kernel
            make -C benchmarks/{{image}} lib
            _app_objects="benchmarks/{{image}}/{{image}}_app.o"
            _app_libs="benchmarks/{{image}}/lib{{image}}.a"
            extra="$extra lto=1"
        fi
    fi
    # Auto-derive extra_cxxflags via print-extra-cxxflags if not specified
    _extra_cxxflags="{{extra_cxxflags}}"
    if [[ -z "$_extra_cxxflags" && -f "benchmarks/{{image}}/Makefile" ]]; then
        _extra_cxxflags=$(make -sC benchmarks/{{image}} print-extra-cxxflags 2>/dev/null || true)
    fi
    if [ ! -d build/last/tools ]; then
        ./scripts/build -j APP_OBJECTS="$_app_objects"
    fi
    extra=""
    [[ -n "$_app_objects" ]] && extra="$extra APP_OBJECTS=\"$_app_objects\""
    [[ -n "$_app_libs" ]] && extra="$extra APP_LIBS=\"$_app_libs\""
    [[ -n "$_extra_cxxflags" ]] && extra="$extra EXTRA_CXXFLAGS=\"$_extra_cxxflags\""
    eval ./scripts/build -j fs=ramfs image={{image}} $extra
    if [[ "{{image}}" == *"duckdb"* ]]; then
        eval ./scripts/build -j fs=ramfs image={{image}} $extra
    fi
    cp {{proot}}/osv/build/last/usr.img {{proot}}/VMs/osv_{{image}}.img

osv_vm nb_cpu="1" size_mem_giga="4G" image="" extra_args="": (bind-ssd-vfio ssd_id) check_downgraded_link
    #!/usr/bin/env bash
    {{proot}}/osv/scripts/imgedit.py setargs {{proot}}/VMs/osv_{{image}}.img "{{extra_args}}"
    let "taskset_cores = {{nb_cpu}}-1"
    sudo taskset -c 0-$taskset_cores qemu-system-x86_64 \
    -m {{size_mem_giga}} \
    -smp {{nb_cpu}} \
    -vnc :1 \
    -device virtio-blk-pci,id=blk0,drive=hd0,scsi=off,bootindex=0 \
    -drive file={{proot}}/VMs/osv_{{image}}.img,if=none,id=hd0,cache=none,aio=native \
    -device vfio-pci,host={{ssd_id}} \
    -netdev user,id=un0,net=192.168.122.0/24,host=192.168.122.1 \
    -device virtio-net-pci,netdev=un0 \
    -device virtio-rng-pci \
    -enable-kvm \
    -cpu host,+x2apic \
    -chardev stdio,mux=on,id=stdio,signal=off \
    -mon chardev=stdio,mode=readline \
    -device isa-serial,chardev=stdio

osv_vm_profile nb_cpu="1" size_mem_giga="4G" image="" extra_args="": (bind-ssd-vfio ssd_id) check_downgraded_link
    #!/usr/bin/env bash
    {{proot}}/osv/scripts/imgedit.py setargs {{proot}}/VMs/osv_{{image}}.img "--sampler=1000 --trace=sampler_tick --noshutdown {{extra_args}}"
    let "taskset_cores = {{nb_cpu}}-1"
    sudo taskset -c 0-$taskset_cores qemu-system-x86_64 \
    -m {{size_mem_giga}} \
    -smp {{nb_cpu}} \
    -vnc :1 \
    -device virtio-blk-pci,id=blk0,drive=hd0,scsi=off,bootindex=0 \
    -drive file={{proot}}/VMs/osv_{{image}}.img,if=none,id=hd0,cache=none,aio=native \
    -device vfio-pci,host={{ssd_id}} \
    -netdev user,id=un0,net=192.168.122.0/24,host=192.168.122.1,hostfwd=tcp::8000-:8000 \
    -device virtio-net-pci,netdev=un0 \
    -device virtio-rng-pci \
    -enable-kvm \
    -cpu host,+x2apic \
    -chardev stdio,mux=on,id=stdio,signal=off \
    -mon chardev=stdio,mode=readline \
    -device isa-serial,chardev=stdio \
    -s

trace-extract tracefile="traces.bin":
    cd {{proot}}/osv && python3 scripts/trace.py extract -e build/last/loader.elf -r localhost:1234 {{proot}}/{{tracefile}}

trace-summary tracefile="traces.bin":
    cd {{proot}}/osv && python3 scripts/trace.py summary {{proot}}/{{tracefile}}

trace-prof tracefile="traces.bin":
    cd {{proot}}/osv && python3 scripts/trace.py prof -e build/last/loader.elf -S {{proot}}/{{tracefile}}

osv_vm_debug nb_cpu="1" size_mem_giga="4G" image="" extra_args="": (bind-ssd-vfio ssd_id) check_downgraded_link
    #!/usr/bin/env bash
    {{proot}}/osv/scripts/imgedit.py setargs {{proot}}/VMs/osv_{{image}}.img "{{extra_args}}"
    let "taskset_cores = {{nb_cpu}}-1"
    sudo taskset -c 0-$taskset_cores qemu-system-x86_64 \
    -m {{size_mem_giga}} \
    -smp {{nb_cpu}} \
    -vnc :1 \
    -device virtio-blk-pci,id=blk0,drive=hd0,scsi=off,bootindex=0 \
    -drive file={{proot}}/VMs/osv_{{image}}.img,if=none,id=hd0,cache=none,aio=native \
    -device vfio-pci,host={{ssd_id}} \
    -netdev user,id=un0,net=192.168.122.0/24,host=192.168.122.1 \
    -device virtio-net-pci,netdev=un0 \
    -device virtio-rng-pci \
    -enable-kvm \
    -cpu host,+x2apic \
    -chardev stdio,mux=on,id=stdio,signal=off \
    -mon chardev=stdio,mode=readline \
    -device isa-serial,chardev=stdio \
    -s

bind-ssd-vfio pci_id="":
    #!/usr/bin/env bash
    current_driver=$(sudo driverctl list-devices | grep {{pci_id}} | awk '{print $2 }')
    [ $current_driver = "vfio-pci" ] || sudo driverctl set-override 0000:{{pci_id}} vfio-pci

bind-ssd-nvme pci_id="":
    #!/usr/bin/env bash
    current_driver=$(sudo driverctl list-devices | grep {{pci_id}} | awk '{print $2 }')
    if [ "$current_driver" != "nvme" ]
    then
        sudo driverctl set-override 0000:{{pci_id}} nvme
    fi

reset_fs confirm="yes":
    #!/usr/bin/env bash
    current_driver=$(sudo driverctl list-devices | grep {{ssd_id}} | awk '{print $2 }')
    if [ "$current_driver" != "nvme" ]
    then
        sudo driverctl set-override 0000:{{ssd_id}} nvme
    fi
    nvme_path="/dev/$(ls /sys/bus/pci/devices/0000\:{{ssd_id}}/nvme)n1"
    echo "$nvme_path"
    if [ "{{confirm}}" == "yes" ]
    then
      read -p "This will overwrite SSD {{ssd_id}} (Host block device path: $nvme_path). Are you sure you want to continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Cancelling"
      exit 1
    fi
    fi
    sudo mke2fs -F -t ext4 -O ^metadata_csum ${nvme_path}
    tmpdir=$(mktemp -d)
    sudo mount ${nvme_path} $tmpdir
    sudo touch $tmpdir/cache
    sudo fallocate -z -l 1500G $tmpdir/cache
    sudo dd if=/dev/zero of=$tmpdir/cache bs=1M count=1331200 oflag=nonblock,direct status=progress
    sudo umount $tmpdir
    sudo driverctl set-override 0000:{{ssd_id}} vfio-pci

check_downgraded_link:
    #!/usr/bin/env bash
    output=$(cat /sys/bus/pci/devices/0000\:{{ssd_id}}/current_link_speed | cut -d' ' -f1)
    if [[ "$output" == "2.5" ]]; then
      # Taken from https://alexforencich.com/wiki/en/pcie/set-speed
      dev="{{ssd_id}}"
      speed="32"
      if [ ! -e "/sys/bus/pci/devices/$dev" ]; then
        dev="0000:$dev"
      fi
      if [ ! -e "/sys/bus/pci/devices/$dev" ]; then
        echo "Error: device $dev not found"
        exit 1
      fi
      pciec=$(sudo setpci -s $dev CAP_EXP+02.W)
      pt=$((("0x$pciec" & 0xF0) >> 4))
      port=$(basename $(dirname $(readlink "/sys/bus/pci/devices/$dev")))
      if (($pt == 0)) || (($pt == 1)) || (($pt == 5)); then
        dev=$port
      fi
      lc=$(sudo setpci -s $dev CAP_EXP+0c.L)
      ls=$(sudo setpci -s $dev CAP_EXP+12.W)
      max_speed=$(("0x$lc" & 0xF))
      if [ -z "$speed" ]; then
        speed=$max_speed
      fi
      if (($speed > $max_speed)); then
        speed=$max_speed
      fi
      lc2=$(sudo setpci -s $dev CAP_EXP+30.L)
      lc2n=$(printf "%08x" $((("0x$lc2" & 0xFFFFFFF0) | $speed)))
      sudo setpci -s $dev CAP_EXP+30.L=$lc2n
      lc=$(sudo setpci -s $dev CAP_EXP+10.L)
      lcn=$(printf "%08x" $(("0x$lc" | 0x20)))
      sudo setpci -s $dev CAP_EXP+10.L=$lcn
      sleep 0.1
      ls=$(sudo setpci -s $dev CAP_EXP+12.W)
    fi
