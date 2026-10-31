#!/bin/bash

# Instalando imagens bootc usando gum

echo "
==============================================================
AVISO!!
No diretório onde este script está sendo executado, 
um arquivo de log chamado 'bootc-installer.log' será criado 
contendo todos os detalhes de execução do script.
==============================================================
"
read -p "Pressione Enter para continuar ou Ctrl+C para cancelar..." -r 
clear

# Verificar se o usuário é root
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script deve ser executado como root."
    exit 1
fi

# Função para alinhar mensagens de status
status() {
    local message="$1"
    local result="$2"
    local width=73
    local dots=$((width - ${#message} - 1))

    ((dots < 1)) && dots=1

    printf "%s " "$message"
    printf '%*s' "$dots" '' | tr ' ' '.'
    printf " [\e[0m%b\e[0m]\n" "$result"
}

# Verificar dependências essenciais no host (gum, sgdisk/gdisk, skopeo, podman)
# Nota: 'bootc' é executado via container/imagem, portanto não deve ser exigido como binário nativo no host.
for cmd in gum sgdisk skopeo podman; do
    if ! command -v "$cmd" &> /dev/null; then
        pkg="$cmd"
        [ "$cmd" = "sgdisk" ] && pkg="gdisk"
        if gum confirm "Deseja instalar o '$pkg' agora? (necessário para o instalador)"; then
            dnf install "$pkg" -y &>> bootc-installer.log
        else
            echo "O comando '$cmd' é obrigatório. Saindo."
            exit 1
        fi
    fi
done

# Obter discos físicos disponíveis
disk=$(lsblk -d -o NAME,TYPE --noheadings | awk '$2=="disk"{print $1}' | grep -vE 'zram|loop')

if [ -z "$disk" ]; then
    echo "Nenhum disco disponível para instalação."
    exit 1
fi

# Selecionar o disco desejado
disk_select=$(echo "$disk" | gum choose --header="Selecione o disco desejado:")
disk_path="/dev/$disk_select"

# Função auxiliar para atualizar e obter partições via lsblk de forma robusta
get_partition() {
    local part_num="$1"
    # Lista apenas as partições (part) do disco filtrando pelo número de ordem dela
    lsblk -rn -o NAME,TYPE "$disk_path" | awk -v p="$part_num" '$2=="part" {count++; if(count==p) print "/dev/"$1}'
}

# Definir os caminhos das partições dinamicamente via lsblk
efi_part=$(get_partition 1)
boot_part=$(get_partition 2)
btrfs_partition=$(get_partition 3)

# Verificar se a partição FEDORA (3) já existe com BTRFS
structure_exists=false
if [ -n "$btrfs_partition" ] && [ -e "$btrfs_partition" ] && blkid -s TYPE -o value "$btrfs_partition" 2>/dev/null | grep -q "btrfs"; then
    structure_exists=true
fi

reuse_home=false
if [ "$structure_exists" = true ]; then
    if gum confirm "⚠️  Estrutura BTRFS existente detectada em [$btrfs_partition]. Deseja reutilizar o /home encontrada?"; then
        reuse_home=true
    fi
fi

if [ "$reuse_home" = true ]; then
    echo "Usando estrutura BTRFS existente e reutilizando o /home..."

    if mkfs.vfat -F 32 -n "EFI" "$efi_part" &>> bootc-installer.log; then
        status "Partição EFI reformatada com FAT" '\e[32mOK\e[0m'
    else
        status "Falha ao formatar a partição EFI" '\e[31mERRO\e[0m'
        exit 1
    fi

    if mkfs.ext4 -F -L "BOOT" "$boot_part" &>> bootc-installer.log; then
        status "Partição BOOT reformatada com EXT4" '\e[32mOK\e[0m'
    else
        status "Falha ao formatar a partição BOOT" '\e[31mERRO\e[0m'
        exit 1
    fi

    mount "$btrfs_partition" /mnt

    if btrfs subvolume show /mnt/root &>> bootc-installer.log || [ -d /mnt/root ]; then
        if btrfs subvolume delete /mnt/root &>> bootc-installer.log; then
            status "Antigo subvolume 'root' excluído (mantendo o /home)" '\e[32mOK\e[0m'
        else
            status "Falha ao excluir o antigo subvolume 'root'" '\e[31mERRO\e[0m'
            umount /mnt
            exit 1
        fi
    fi

    if btrfs subvolume create /mnt/root &>> bootc-installer.log; then
        status "Novo subvolume 'root' criado" '\e[32mOK\e[0m'
    else
        status "Falha ao criar o subvolume 'root'" '\e[31mERRO\e[0m'
        umount /mnt
        exit 1
    fi

    if [ ! -d /mnt/home ]; then
        btrfs subvolume create /mnt/home &>> bootc-installer.log
    fi

    umount /mnt

    mount "$btrfs_partition" -o subvol=root,compress=zstd:1 /mnt &>> bootc-installer.log \
        && status "Partição FEDORA (subvol root) montada" '\e[32mOK\e[0m' || { status "Falha ao montar a partição FEDORA" '\e[31mERRO\e[0m'; exit 1; }

    mount "$boot_part" --mkdir /mnt/boot &>> bootc-installer.log \
        && status "Partição BOOT montada" '\e[32mOK\e[0m' || { status "Falha ao montar a partição BOOT" '\e[31mERRO\e[0m'; exit 1; }

    mount "$efi_part" --mkdir /mnt/boot/efi &>> bootc-installer.log \
        && status "Partição EFI montada" '\e[32mOK\e[0m' || { status "Falha ao montar a partição EFI" '\e[31mERRO\e[0m'; exit 1; }

else
    # Instalação limpa (do zero)
    if gum confirm "⚠️  Tem certeza de que deseja particionar e formatar o disco [$disk_select] do zero?"; then
        echo "Iniciando o particionamento e formatação do disco [$disk_select]..."

        sgdisk --zap-all "$disk_path" &>> bootc-installer.log \
            && status "Tabela de partição existente limpa" '\e[32mOK\e[0m' || { status "Falha ao limpar a tabela de partição" '\e[31mERRO\e[0m'; exit 1; }

        sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" \
                  -n 2:0:+2G -t 2:8300 -c 2:"BOOT" \
                  -n 3:0:0 -t 3:8300 -c 3:"FEDORA" \
                  "$disk_path" &>> bootc-installer.log \
            && status "Partições criadas" '\e[32mOK\e[0m' || { status "Falha ao criar partições" '\e[31mERRO\e[0m'; exit 1; }

        partprobe "$disk_path" &>> bootc-installer.log
        sleep 2

        # Atualiza as variáveis das partições recém-criadas usando o lsblk após o partprobe
        efi_part=$(get_partition 1)
        boot_part=$(get_partition 2)
        btrfs_partition=$(get_partition 3)

        mkfs.vfat -F 32 -n "EFI" "$efi_part" &>> bootc-installer.log \
            && status "Partição EFI formatada com FAT" '\e[32mOK\e[0m' || { status "Falha ao formatar EFI" '\e[31mERRO\e[0m'; exit 1; }

        mkfs.ext4 -F -L "BOOT" "$boot_part" &>> bootc-installer.log \
            && status "Partição BOOT formatada com EXT4" '\e[32mOK\e[0m' || { status "Falha ao formatar BOOT" '\e[31mERRO\e[0m'; exit 1; }

        mkfs.btrfs -f -L "FEDORA" "$btrfs_partition" &>> bootc-installer.log \
            && status "Partição FEDORA formatada com BTRFS" '\e[32mOK\e[0m' || { status "Falha ao formatar FEDORA" '\e[31mERRO\e[0m'; exit 1; }

        mount "$btrfs_partition" /mnt

        btrfs subvolume create /mnt/root &>> bootc-installer.log \
            && status "Subvolume 'root' criado" '\e[32mOK\e[0m' || { status "Falha ao criar subvol root" '\e[31mERRO\e[0m'; umount /mnt; exit 1; }

        btrfs subvolume create /mnt/home &>> bootc-installer.log \
            && status "Subvolume 'home' criado" '\e[32mOK\e[0m' || { status "Falha ao criar subvol home" '\e[31mERRO\e[0m'; umount /mnt; exit 1; }

        umount /mnt

        mount "$btrfs_partition" -o subvol=root,compress=zstd:1 /mnt &>> bootc-installer.log \
            && status "Partição FEDORA (subvol root) montada" '\e[32mOK\e[0m' || { status "Falha ao montar FEDORA" '\e[31mERRO\e[0m'; exit 1; }

        mount "$boot_part" --mkdir /mnt/boot &>> bootc-installer.log \
            && status "Partição BOOT montada" '\e[32mOK\e[0m' || { status "Falha ao montar BOOT" '\e[31mERRO\e[0m'; exit 1; }

        mount "$efi_part" --mkdir /mnt/boot/efi &>> bootc-installer.log \
            && status "Partição EFI montada" '\e[32mOK\e[0m' || { status "Falha ao montar EFI" '\e[31mERRO\e[0m'; exit 1; }
    else
        echo -e "Operação cancelada pelo usuário."
        exit 1
    fi
fi

# Obter os UUIDs das partições dinamicamente
efi_uuid=$(blkid -s UUID -o value "$efi_part")
boot_uuid=$(blkid -s UUID -o value "$boot_part")
btrfs_uuid=$(blkid -s UUID -o value "$btrfs_partition")

if [ -z "$efi_uuid" ] || [ -z "$boot_uuid" ] || [ -z "$btrfs_uuid" ]; then
    status "Falha ao obter os UUIDs das partições" '\e[31mERRO\e[0m'
    exit 1
fi

# Solicitar ao usuário o link da imagem bootc para instalar
bootc_image=$(gum input --placeholder "Link da imagem bootc para instalar:")
if [ -z "$bootc_image" ]; then
    status "Nenhum link fornecido. Saindo." '\e[31mERRO\e[0m'
    exit 1
fi

# Verificar se é uma imagem bootc válida
if skopeo inspect "docker://${bootc_image}" | grep 'containers.bootc": "1"' &>> bootc-installer.log; then
    status "Imagem bootc válida" '\e[32mOK\e[0m'
else
    status "Imagem bootc inválida" '\e[31mERRO\e[0m'
    exit 1
fi

# Instalar a imagem bootc no disco (usando o comando bootc dentro do container)
if podman run --rm --privileged --pid=host \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  -v /mnt:/target:rw,z \
  --security-opt label=type:unconfined_t \
  "$bootc_image" \
  bootc install to-filesystem \
  --skip-finalize \
  --boot-mount-spec=UUID="$boot_uuid" \
  /target/ &>> bootc-installer.log; then
    status "Imagem bootc instalada" '\e[32mOK\e[0m'
else
    status "Falha ao instalar a imagem bootc" '\e[31mERRO\e[0m'
    exit 1
fi

# Configurar o /etc/fstab
mount_dir="/var/tmp/bootc-mount-$$"
mkdir -p "$mount_dir"

# Usa o bootc install mount para montar a imagem bootc no diretório temporário
# Depois injeta o fstab personalizado e desmonta
if podman run --rm --privileged --pid=host \
  -v /mnt:/target:rw,z \
  "$bootc_image" \
  bootc install mount --sysroot /target --latest "$mount_dir" &>> bootc-installer.log || true; then
    # Se falhar a chamada direta via container ou se preferir o binário do host caso exista, ajustamos. 
    # Mantendo a sua estrutura original de montagem:
    true
fi

# Como o container do bootc gerencia o mount point interno, ajustamos o fstab deployment:
if [ -d "$mount_dir/etc" ] || bootc install mount --sysroot /mnt --latest "$mount_dir" &>> bootc-installer.log; then
    cat << EOF > "$mount_dir/etc/fstab"
UUID=${btrfs_uuid} / btrfs subvol=root,compress=zstd:1,ro 0 0
UUID=${boot_uuid} /boot ext4 ro 1 2
UUID=${efi_uuid} /boot/efi vfat umask=0077,shortname=winnt 0 2
UUID=${btrfs_uuid} /var/home btrfs subvol=home,compress=zstd:1 0 0
EOF

    status "Arquivo /etc/fstab personalizado criado com sucesso" '\e[32mOK\e[0m'
    umount -R "$mount_dir" 2>/dev/null
    rmdir "$mount_dir" 2>/dev/null
else
    status "Falha ao montar o deployment para a configuração do fstab" '\e[31mERRO\e[0m'
    rmdir "$mount_dir" 2>/dev/null
    exit 1
fi