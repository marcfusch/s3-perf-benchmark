#!/usr/bin/env bash
# hdd.sh attach|detach|limit <system> <node>
# Gives one node a modelled consumer hard disk instead of the shared SSD.
#
#   attach  (cluster created but not started) a sparse file on the docker
#           disk becomes a loop device, dm-delay adds a fixed delay to every
#           IO (HDD_READ_MS, HDD_WRITE_MS, HDD_FLUSH_MS), it is formatted in
#           ext4 and mounted on the node volume, in the host mount namespace
#   limit   (container running) io.max on the dm device caps the IOPS
#           (HDD_RIOPS, HDD_WIOPS) and the throughput (the nominal budget):
#           dm-delay alone delays IOs in parallel, a disk has one head
#   detach  (containers removed) unmount and remove everything
#
# Model and sources (see the report): a 7200 rpm desktop disk needs about
# 13 ms per random access (8.9 ms seek + 4.2 ms rotation) and does about
# 75 to 130 random IOPS at queue depth 1, up to ~150 to 200 with NCQ; its
# cache absorbs writes, while a flush waits for the platter.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cmd=$1 sys=$2 n=$3
HDD_READ_MS=${HDD_READ_MS:-13}
HDD_WRITE_MS=${HDD_WRITE_MS:-2}
HDD_FLUSH_MS=${HDD_FLUSH_MS:-20}
HDD_RIOPS=${HDD_RIOPS:-150}
HDD_WIOPS=${HDD_WIOPS:-200}
HDD_SIZE=${HDD_SIZE:-4G}
name="hdd-$sys-$n"
img="/var/lib/docker/hdd/$name.img"
vol="/var/lib/docker/volumes/${sys}_d$n/_data"

priv() {
  docker run --rm --privileged --pid=host -v /var/lib/docker:/var/lib/docker -v /dev:/dev \
    "$TOOLS_IMAGE" sh -c "$1"
}

case "$cmd" in
  attach)
    priv "set -e
      nsenter -t 1 -m -- modprobe dm_delay
      mkdir -p /var/lib/docker/hdd && rm -f $img && truncate -s $HDD_SIZE $img
      loop=\$(losetup --direct-io=on -f --show $img)
      sz=\$(blockdev --getsz \$loop)
      dmsetup create $name --table \"0 \$sz delay \$loop 0 $HDD_READ_MS \$loop 0 $HDD_WRITE_MS \$loop 0 $HDD_FLUSH_MS\"
      mkfs.ext4 -q -F /dev/mapper/$name
      dev=\$(dmsetup info -c --noheadings -o major,minor $name | tr -d ' ')
      nsenter -t 1 -m -- sh -c \"mknod /tmp/$name b \${dev%:*} \${dev#*:} 2>/dev/null || true; mount /tmp/$name $vol && rmdir $vol/lost+found\"
      echo 1 > /sys/block/dm-\${dev#*:}/queue/rotational 2>/dev/null || true
      echo \"$name attached on $vol (\$dev)\""
    ;;
  limit)
    dev=$(priv "dmsetup info -c --noheadings -o major,minor $name" | tr -d ' ')
    cg=$(cgroup_of "$sys-node$n")
    host_tool sh -c "echo '$dev rbps=$DISK_RBPS wbps=$DISK_WBPS riops=$HDD_RIOPS wiops=$HDD_WIOPS' > /sys/fs/cgroup$cg/io.max"
    echo "{\"hdd\":\"$name\",\"dev\":\"$dev\",\"read_ms\":$HDD_READ_MS,\"write_ms\":$HDD_WRITE_MS,\"flush_ms\":$HDD_FLUSH_MS,\"riops\":$HDD_RIOPS,\"wiops\":$HDD_WIOPS,\"rbps\":$DISK_RBPS,\"wbps\":$DISK_WBPS}"
    ;;
  detach)
    priv "nsenter -t 1 -m -- sh -c 'umount $vol 2>/dev/null; rm -f /tmp/$name' || true
      dmsetup remove $name 2>/dev/null || true
      for l in \$(losetup -j $img 2>/dev/null | cut -d: -f1); do losetup -d \$l; done
      rm -f $img"
    ;;
  *) echo "usage: hdd.sh attach|detach|limit <system> <node>" >&2; exit 1 ;;
esac
