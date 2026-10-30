# Bootc Disk Installer (`bootc-installer.sh`)

Um script de terminal interativo e robusto desenvolvido para automatizar o particionamento, a formatação e a implantação de imagens de SO baseadas em OCI diretamente em um disco físico usando o **`bootc install to-filesystem`**.

Construído especificamente para sistemas operacionais containerizados baseados em Fedora/RHEL (bootc), esta ferramenta aproveita utilitários modernos de CLI como `gum` para uma experiência de TUI intuitiva, `sgdisk` para particionamento preciso de disco, `btrfs` com subvolumes e compressão, e `podman` / `bootc` para a instalação final da imagem.

---

## ✨ Recursos

* **TUI Interativa:** Desenvolvida com o `gum` da Charmbracelet para prompts limpos, verificações e seleção de disco.
* **Filtragem Inteligente de Disco:** Detecta automaticamente drives físicos enquanto ignora dispositivos loop, CD-ROMs e `zram`.
* **Detecção e Reutilização do Subvolume Home:** Detecta automaticamente a existência de um subvolume `home` anterior em uma partição BTRFS e pergunta ao usuário se ele deseja reutilizá-lo, preservando os dados do usuário durante a reinstalação.
* **Layout de Partição Moderno:**
* **Partição de Sistema EFI (ESP):** Formatada em FAT32 (`+1G`).
* **Partição Boot (`/boot`):** Formatada em EXT4 (`+2G`).
* **Partição Raiz (`/FEDORA`):** Formatada em BTRFS, contando com subvolumes estruturados (`root`, `home`) e compressão `zstd` (`compress=zstd:1`).


* **Verificação de Imagem:** Valida a imagem OCI de destino via `skopeo` para garantir que ela contém uma configuração bootc válida (`containers.bootc: "1"`).
* **Execução Segura:** Executa a rotina `bootc install to-filesystem` de forma segura dentro de uma instância de contêiner do Podman com privilégios, apontando para o sistema de arquivos montado.
* **Registro de Logs Completo:** Registra automaticamente todas as etapas da instalação e saídas de comandos no arquivo `bootc-installer.log` dentro do diretório de trabalho.

---

## 📋 Pré-requisitos

O script requer privilégios de root e oferecerá automaticamente a verificação ou instalação das dependências ausentes via `dnf`:

* **`gum`** (Componentes de interface interativa)
* **`gdisk` / `sgdisk**` (Ferramenta de particionamento GPT)
* **`skopeo`** (Inspeção de imagens de contêiner)
* **`podman`** (Runtime de contêiner)
* **`bootc`** (Utilitário de instalação de contêiner inicializável)

---

## 🚀 Como Usar

1. Clone ou baixe o script para o seu ambiente.
2. Torne o script executável:
```bash
chmod +x bootc-installer.sh

```


3. Execute o script com **privilégios de root**:
```bash
sudo ./bootc-installer.sh

```


4. Siga as instruções interativas na tela:
* Confirme o aviso e a criação do arquivo de log.
* Selecione o disco de instalação de destino na lista.
* Caso um subvolume `home` existente seja detectado na partição BTRFS, escolha se deseja mantê-lo e reutilizá-lo ou sobrescrevê-lo.
* Confirme a ação de particionamento e formatação.
* Informe a referência da imagem do contêiner (ex: `ghcr.io/seu-usuario/sua-imagem-bootc:latest`).



---

## 📂 Estrutura de Particionamento Criada

| Partição | Ponto de Montagem | Sistema de Arquivos | Tamanho / Notas |
| --- | --- | --- | --- |
| **Partição 1** | `/mnt/boot/efi` | FAT32 | `1 GB` (Partição de Sistema EFI) |
| **Partição 2** | `/mnt/boot` | EXT4 | `2 GB` (Partição de Boot Dedicada) |
| **Partição 3** | `/mnt` (`subvol=root`) | BTRFS | Espaço restante (subvolume raiz comprimido com `zstd`) |
| **Partição 3** | (Criado no disco) | BTRFS | Subvolume `/home` (suporta reutilização para preservar dados) |

---

## 📝 Registros de Logs

Todas as saídas de stdout e stderr durante a execução são capturadas e anexadas ao arquivo `bootc-installer.log` no diretório onde o script é executado. Consulte este arquivo para obter detalhes de depuração caso alguma etapa falhe.