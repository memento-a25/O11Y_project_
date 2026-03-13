#!/usr/bin/env bash
set -eo pipefail


if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Этот скрипт должен запускаться от имени root (используй sudo)."
  exit 1
fi

#####  БЛОК ПЕРЕМЕННЫХ ###########################################################################################################

INTERNAL_BRIDGE="br-internal"
NETPLAN_CONFIG=/etc/netplan/99-bridge.yaml
CLONE_PATH="/var/lib/libvirt/images"
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICKpRGqQLoCHTVBQHSXrOgiY1hC/lrWWlRXACNFvKDLZ admin1@admin1-MS-7C75"
IMAGE_PATH="/var/lib/libvirt/images/templates/AlmaLinux-9-GenericCloud-9.7-20251118.x86_64.qcow2"
Alma_Download_Link=https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-9.7-20251118.x86_64.qcow2
Alma_HASHSUM=https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/CHECKSUM
AlmaVersionName=AlmaLinux-9-GenericCloud-9.7-20251118.x86_64.qcow2
NODES=(
    "elk-node-1;192.168.100.9;52:54:00:11:22:33;52:54:00:44:55:66"
    "master-node-1;192.168.100.10;52:54:00:12:23:34;52:54:00:41:52:63"
    "worker-node-1;192.168.100.11;52:54:00:13:24:35;52:54:00:42:53:64"
    "worker-node-2;192.168.100.12;52:54:00:14:25:36;52:54:00:43:54:65"
)

#### БЛОК ПРОВЕРКИ ГОТОВНОСТИ ЗОЛОТОГО ОБРАЗА ######################################################################################

IMAGE_TMP="${IMAGE_PATH}.tmp"

mkdir -p /var/lib/libvirt/images/templates

if ! [ -f "$IMAGE_PATH" ]; then
  echo "[INFO] Золотой образ не найден или не завершен. Начинаю подготовку..."

  if ! command -v virt-customize > /dev/null 2>&1; then
     echo "virt-customize не установлен в системе, произвожу установку libguestfs-tools..."
     apt-get install -y -q libguestfs-tools
  fi

  if ! command -v cloud-localds > /dev/null 2>&1; then
     echo "cloud-utils не установлен в системе, устанавливаю..."
     apt-get install -y -q cloud-utils
  fi

    echo "[INFO] Скачиваю во временный файл $IMAGE_TMP..."
    wget -c --tries=3 --retry-connrefused --show-progress -O "$IMAGE_TMP" "$Alma_Download_Link"
    wget -c --tries=3 --retry-connrefused --show-progress -O /tmp/CHECKSUM "$Alma_HASHSUM"
    HASH=$(grep "$AlmaVersionName" /tmp/CHECKSUM | awk '{print $1}')
    echo "$HASH  $IMAGE_TMP" | sha256sum -c - || { echo "ОШИБКА: Хеш образа не совпал с контрольной суммой"; exit 1; }

#  echo "[INFO] Настраиваю образ..."
#  virt-customize -q -a "$IMAGE_TMP" \
#  --network \
#  --edit '/etc/resolv.conf: s/nameserver.*/nameserver 8.8.8.8/' \
#  --run-command "echo 'nameserver 8.8.8.8' > /etc/resolv.conf" \
#  --run-command "sed -i 's/^mirrorlist/#mirrorlist/g' /etc/yum.repos.d/almalinux-*.repo" \
#  --run-command "sed -i 's|^#baseurl=http://mirror.almalinux.org/almalinux/|baseurl=https://repo.almalinux.org/almalinux/|g' /etc/yum.repos.d/almalinux-*.repo" \
#  --run-command "dnf clean all" \
#  --install qemu-guest-agent \
#  --hostname almalinux9-template

  echo "[INFO] Запечатываю (sysprep)..."
  virt-sysprep -a "$IMAGE_TMP"

  mv "$IMAGE_TMP" "$IMAGE_PATH"
  echo "[SUCCESS] Золотой образ полностью готов и перемещен в финальную директорию."

else
  echo "[SKIP] Золотой образ уже существует и готов к работе."
fi

#### БЛОК ПРОВЕРКИ СОЗДАННОГО ИНТЕРФЕЙСА ДЛЯ ВИРТУАЛОК ########################################\#####################################

  if ! [ -f "$NETPLAN_CONFIG" ]; then
    echo "[INFO] Конфигурация Netplan для $INTERNAL_BRIDGE не найдена. Создаю..."
    cat <<EOF > "$NETPLAN_CONFIG"
network:
  version: 2
  renderer: networkd
  bridges:
    $INTERNAL_BRIDGE:
      interfaces: []
      addresses: [192.168.100.1/24]
      parameters:
        stp: false
        forward-delay: 0
EOF

    netplan apply || { echo "[ERROR] Ошибка конфига"; exit 1; }
    echo "[SUCCESS] Сеть $INTERNAL_BRIDGE настроена и будет сохранена после перезагрузки."
    if ! ip link show "$INTERNAL_BRIDGE" > /dev/null 2>&1; then
      { echo "[ERROR] Сеть $INTERNAL_BRIDGE не поднялась, прерываю выполнение скрипта"; exit 1; }
    fi
 else
    echo "[SKIP] Конфигурация $INTERNAL_BRIDGE уже существует."
  fi

#### БЛОК СОЗДАНИЯ ВМ ##############################################################################################################

for vm in "${NODES[@]}"; do
    IFS=';' read vm_name vm_ip vm_mac_eth0 vm_mac_eth1 <<< "$vm"

    if ! virsh domid "$vm_name" > /dev/null 2>&1; then
      echo "[INFO] Начинаю создание ноды $vm_name..."

#### БЛОК ПЕРЕМЕННЫХ НОД ###########################################################################################################

      VM_MEM=4096
      VM_CPU=2

      if [[ "$vm_name" == "elk-node-1" || "$vm_name" == "master-node-1" ]]; then

        VM_MEM=8192
        VM_CPU=4
        echo "[INFO] Для $vm_name выделено больше ресурсов: RAM $VM_MEM, CPU $VM_CPU"
      fi

#### СОЗДАНИЕ ВМ ###################################################################################################################

      qemu-img create -f qcow2 -F qcow2 -q -b "$IMAGE_PATH" "$CLONE_PATH/$vm_name.qcow2" 30G

      mkdir -p "/tmp/$vm_name"

      cat <<EOF > "/tmp/$vm_name/network-config.yaml"
version: 2
ethernets:
  eth0:
    match:
      macaddress: '$vm_mac_eth0'
    set-name: eth0
    dhcp4: true
  eth1:
    match:
      macaddress: '$vm_mac_eth1'
    set-name: eth1
    addresses:
      - $vm_ip/24
EOF



      cat <<EOF > "/tmp/$vm_name/user-data.yaml"
#cloud-config
users:
  - name: ansible
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - "$SSH_KEY"
EOF



      cat <<EOF > "/tmp/$vm_name/meta-data.yaml"
instance-id: $vm_name
local-hostname: $vm_name
EOF

      echo "[INFO] Генерирую seed-образ для $vm_name..."
      SEED_ISO="$CLONE_PATH/$vm_name-seed.iso"


      cloud-localds "$SEED_ISO" \
        "/tmp/$vm_name/user-data.yaml" \
        "/tmp/$vm_name/meta-data.yaml" \
        --network-config="/tmp/$vm_name/network-config.yaml"



      echo "Создаю ноду $vm_name..."

      virt-install --name "$vm_name" \
      --memory "$VM_MEM" \
      --vcpus "$VM_CPU" \
      --cpu host-passthrough \
      --disk path="$CLONE_PATH/$vm_name.qcow2",format=qcow2,bus=virtio \
      --disk path="$SEED_ISO",device=cdrom \
      --network network=default,model=virtio,mac="$vm_mac_eth0" \
      --network bridge="$INTERNAL_BRIDGE",model=virtio,mac="$vm_mac_eth1" \
      --import \
      --graphics none \
      --console pty,target_type=serial \
      --virt-type kvm \
      --os-variant almalinux9 \
      --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
      --rng /dev/urandom,model=virtio \
      --noautoconsole

      rm -rf "/tmp/$vm_name"
      echo "[SUCCESS] Нода $vm_name успешно развернута."

    else
      echo "[SKIP] Нода $vm_name уже существует. Пропускаю этап создания дисков и конфигов."
    fi
done
