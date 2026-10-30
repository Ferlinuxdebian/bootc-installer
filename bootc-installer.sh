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

# Verificar se o gum está instalado
if ! command -v gum &> /dev/null; then
    read -p "Deseja instalar o gum agora? (necessário para a interface de seleção) [s/n]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[YySs]$ ]]; then
        dnf install gum -y &>> bootc-installer.log
    else
        echo "O gum não está instalado. Por favor, instale o gum antes de continuar."
        exit 1
    fi
fi

# Verificar se o sgdisk está instalado
if ! command -v sgdisk &> /dev/null; then
    if gum confirm "Deseja instalar o sgdisk agora? (necessário para particionar discos)"; then
        dnf install gdisk -y &>> bootc-installer.log
    else
        echo "O sgdisk não está instalado. Por favor, instale o sgdisk antes de continuar."
        exit 1
    fi
fi

# Verificar se o skopeo está instalado
if ! command -v skopeo &> /dev/null; then
    if gum confirm "Deseja instalar o skopeo agora? (necessário para verificar imagens bootc)"; then
        dnf install skopeo -y &>> bootc-installer.log
    else
        echo "O skopeo não está instalado. Por favor, instale o skopeo antes de continuar."
        exit 1
    fi
fi

# Verificar se o podman está instalado
if ! command -v podman &> /dev/null; then
    if gum confirm "Deseja instalar o podman agora? (necessário para instalar imagens bootc)"; then
        dnf install podman -y &>> bootc-installer.log
    else
        echo "O podman não está instalado. Por favor, instale o podman antes de continuar."
        exit 1
    fi
fi

# Verificar se o bootc está instalado
if ! command -v bootc &> /dev/null; then
    if gum confirm "Deseja instalar o bootc agora? (necessário para instalar imagens bootc)"; then
        dnf install bootc -y &>> bootc-installer.log
    else
        echo "O bootc não está instalado. Por favor, instale o bootc antes de continuar."
        exit 1
    fi
fi

# Obter discos disponíveis (filtrando apenas discos físicos, ignorando loops e cd-roms)
disk=$(lsblk -d -o NAME,TYPE --noheadings | awk '$2=="disk"{print $1}' | grep -v zram)

# Verificar se não há discos disponíveis
if [ -z "$disk" ]; then
    echo "Nenhum disco disponível para instalação."
    exit 1
fi

# Selecionar o disco desejado
disk_select=$(echo "$disk" | gum choose --header="Selecione o disco desejado:")

# Verificar se a partição FEDORA já existe com BTRFS
btrfs_partition="/dev/${disk_select}3"
structure_exists=false

if [ -e "$btrfs_partition" ] && blkid -s TYPE -o value "$btrfs_partition" 2>/dev/null | grep -q "btrfs"; then
    structure_exists=true
fi

# Variável para controlar o modo de reutilização
reuse_home=false

if [ "$structure_exists" = true ]; then
    # Verificar se o usuário deseja reutilizar o home e a estrutura existe
    if gum confirm "⚠️  Estrutura BTRFS existente detectada em [$btrfs_partition]. Deseja reutilizar o /home encontrada?"; then
        reuse_home=true
    fi
fi

if [ "$reuse_home" = true ]; then
    echo "Usando estrutura BTRFS existente e reutilizando o /home..."

    # 1. Formatar apenas as partições EFI e BOOT
    if mkfs.vfat -F 32 -n "EFI" "/dev/${disk_select}1" &>> bootc-installer.log; then
        status "Partição EFI reformatada com FAT" '\e[32mOK\e[0m'
    else
        status "Falha ao formatar a partição EFI" '\e[31mERRO\e[0m'
        exit 1
    fi

    if mkfs.ext4 -F -L "BOOT" "/dev/${disk_select}2" &>> bootc-installer.log; then
        status "Partição BOOT reformatada com EXT4" '\e[32mOK\e[0m'
    else
        status "Falha ao formatar a partição BOOT" '\e[31mERRO\e[0m'
        exit 1
    fi

    # 2. Montar o nível superior do BTRFS para gerenciar subvolumes
    mount "$btrfs_partition" /mnt

    # Excluir o subvolume root se ele existir
    if btrfs subvolume show /mnt/root &>> bootc-installer.log || [ -d /mnt/root ]; then
        if btrfs subvolume delete /mnt/root &>> bootc-installer.log; then
            status "Antigo subvolume 'root' excluído (mantendo o /home)" '\e[32mOK\e[0m'
        else
            status "Falha ao excluir o antigo subvolume 'root'" '\e[31mERRO\e[0m'
            umount /mnt
            exit 1
        fi
    fi

    # Recriar o subvolume root
    if btrfs subvolume create /mnt/root &>> bootc-installer.log; then
        status "Novo subvolume 'root' criado" '\e[32mOK\e[0m'
    else
        status "Falha ao criar o subvolume 'root'" '\e[31mERRO\e[0m'
        umount /mnt
        exit 1
    fi

    # Garantir que o subvolume home exista por precaução
    if [ ! -d /mnt/home ]; then
        btrfs subvolume create /mnt/home &>> bootc-installer.log
    fi

    umount /mnt

    # Montar o subvolume root em /mnt com compactação
    if mount "$btrfs_partition" -o subvol=root,compress=zstd:1 /mnt &>> bootc-installer.log; then
        status "Partição FEDORA (subvol root) montada" '\e[32mOK\e[0m'
    else
        status "Falha ao montar a partição FEDORA" '\e[31mERRO\e[0m'
        exit 1
    fi

    # Montar a partição boot em /mnt/boot
    if mount "/dev/${disk_select}2" --mkdir /mnt/boot &>> bootc-installer.log; then
        status "Partição BOOT montada" '\e[32mOK\e[0m'
    else
        status "Falha ao montar a partição BOOT" '\e[31mERRO\e[0m'
        exit 1
    fi

    # Montar a partição EFI em /mnt/boot/efi
    if mount "/dev/${disk_select}1" --mkdir /mnt/boot/efi &>> bootc-installer.log; then
        status "Partição EFI montada" '\e[32mOK\e[0m'
    else
        status "Falha ao montar a partição EFI" '\e[31mERRO\e[0m'
        exit 1
    fi

else
    # Fluxo de trabalho de instalação limpa (do zero)
    if gum confirm "⚠️  Tem certeza de que deseja particionar e formatar o disco [$disk_select] do zero?"; then
        echo "Iniciando o particionamento e formatação do disco [$disk_select]..."

        if sgdisk --zap-all "/dev/$disk_select" &>> bootc-installer.log; then
            status "Tabela de partição existente limpa" '\e[32mOK\e[0m'
        else
            status "Falha ao limpar a tabela de partição existente" '\e[31mERRO\e[0m'
            exit 1
        fi

        if sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" \
                  -n 2:0:+2G -t 2:8300 -c 2:"BOOT" \
                  -n 3:0:0 -t 3:8300 -c 3:"FEDORA" \
                  "/dev/$disk_select" &>> bootc-installer.log; then
            status "Partições criadas" '\e[32mOK\e[0m'
        else
            status "Falha ao criar partições" '\e[31mERRO\e[0m'
            exit 1
        fi

        partprobe "/dev/$disk_select" &>> bootc-installer.log
        sleep 2

        if mkfs.vfat -F 32 -n "EFI" "/dev/${disk_select}1" &>> bootc-installer.log; then
            status "Partição EFI formatada com FAT" '\e[32mOK\e[0m'
        else
            status "Falha ao formatar a partição EFI" '\e[31mERRO\e[0m'
            exit 1
        fi

        if mkfs.ext4 -F -L "BOOT" "/dev/${disk_select}2" &>> bootc-installer.log; then
            status "Partição BOOT formatada com EXT4" '\e[32mOK\e[0m'
        else
            status "Falha ao formatar a partição BOOT" '\e[31mERRO\e[0m'
            exit 1
        fi

        if mkfs.btrfs -f -L "FEDORA" "/dev/${disk_select}3" &>> bootc-installer.log; then
            status "Partição FEDORA formatada com BTRFS" '\e[32mOK\e[0m'
        else
            status "Falha ao formatar a partição FEDORA" '\e[31mERRO\e[0m'
            exit 1
        fi

        mount "/dev/${disk_select}3" /mnt

        if btrfs subvolume create /mnt/root &>> bootc-installer.log; then
            status "Subvolume 'root' criado" '\e[32mOK\e[0m'
        else
            status "Falha ao criar o subvolume 'root'" '\e[31mERRO\e[0m'
            umount /mnt
            exit 1
        fi

        if btrfs subvolume create /mnt/home &>> bootc-installer.log; then
            status "Subvolume 'home' criado" '\e[32mOK\e[0m'
        else
            status "Falha ao criar o subvolume 'home'" '\e[31mERRO\e[0m'
            umount /mnt
            exit 1
        fi

        umount /mnt

        if mount "/dev/${disk_select}3" -o subvol=root,compress=zstd:1 /mnt &>> bootc-installer.log; then
            status "Partição FEDORA (subvol root) montada" '\e[32mOK\e[0m'
        else
            status "Falha ao montar a partição FEDORA" '\e[31mERRO\e[0m'
            exit 1
        fi

        if mount "/dev/${disk_select}2" --mkdir /mnt/boot &>> bootc-installer.log; then
            status "Partição BOOT montada" '\e[32mOK\e[0m'
        else
            status "Falha ao montar a partição BOOT" '\e[31mERRO\e[0m'
            exit 1
        fi

        if mount "/dev/${disk_select}1" --mkdir /mnt/boot/efi &>> bootc-installer.log; then
            status "Partição EFI montada" '\e[32mOK\e[0m'
        else
            status "Falha ao montar a partição EFI" '\e[31mERRO\e[0m'
            exit 1
        fi
    else
        echo -e "Operação cancelada pelo usuário."
        exit 1
    fi
fi

# Obter os UUIDs das partições
efi_uuid=$(blkid -s UUID -o value "/dev/${disk_select}1")
boot_uuid=$(blkid -s UUID -o value "/dev/${disk_select}2")
btrfs_uuid=$(blkid -s UUID -o value "/dev/${disk_select}3")

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

# Instalar a imagem bootc no disco (com --skip-finalize para permitir a edição do fstab)
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

# -------------------------------------------------------------------------
# Configurar o /etc/fstab usando o comando mount do bootc ou manipulação direta de montagem
# -------------------------------------------------------------------------
# Cria o ponto de montagem em um diretório temporário válido do host
mount_dir="/var/tmp/bootc-mount-$$"
mkdir -p "$mount_dir"

if bootc install mount --sysroot /mnt --latest "$mount_dir" &>> bootc-installer.log; then
    
    # Gera o fstab customizado sem a linha do /var
    cat << EOF > "$mount_dir/etc/fstab"
UUID=${btrfs_uuid} / btrfs subvol=root,compress=zstd:1,ro 0 0
UUID=${boot_uuid} /boot ext4 ro 1 2
UUID=${efi_uuid} /boot/efi vfat umask=0077,shortname=winnt 0 2
UUID=${btrfs_uuid} /var/home btrfs subvol=home,compress=zstd:1 0 0
EOF

    status "Arquivo /etc/fstab personalizado criado com sucesso" '\e[32mOK\e[0m'
    
    # Desmonta recursivamente e remove o diretório temporário
    umount -R "$mount_dir"
    rmdir "$mount_dir"
else
    status "Falha ao montar o deployment para a configuração do fstab" '\e[31mERRO\e[0m'
    rmdir "$mount_dir" 2>/dev/null
    exit 1
fi