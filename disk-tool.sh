#!/bin/bash

LOG_FILE="$HOME/disk_tool.log"
REPORT_DIR="$HOME/disk_tool_reports"
TMP_MOUNT="/mnt/img_mount"
mkdir -p "$REPORT_DIR" "$TMP_MOUNT"
REQUIRED_TOOLS=(lsblk dd losetup mount umount parted fdisk truncate grep awk xargs sudo zenity gzip sha256sum cmp enscript ps2pdf xdg-open gnuplot tail appimagetool pv kpartx e2fsck resize2fs)

ICON_PATH="$HOME/.local/share/icons/pussinboot.png"
PROGRESS_ICON="dialog-information"

############################################
# Fonctions d'enregistrement et de log
############################################

function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

function generate_pdf_report() {
    report_txt="$REPORT_DIR/report_$(date +%Y%m%d_%H%M%S).txt"
    report_pdf="${report_txt%.txt}.pdf"
    echo "--- Rapport Disk Tool ---" > "$report_txt"
    echo "Date : $(date)" >> "$report_txt"
    echo "Machine : $(hostname)" >> "$report_txt"
    echo "Utilisateur : $USER" >> "$report_txt"
    echo -e "\nDernières lignes du journal :" >> "$report_txt"
    tail -n 20 "$LOG_FILE" >> "$report_txt"
    enscript "$report_txt" -o - | ps2pdf - "$report_pdf"
    xdg-open "$report_pdf" &
}

############################################
# Détection et vérification système
############################################

function detect_system_partition() {
    SYSTEM_PART=$(lsblk -no MOUNTPOINT,NAME | grep ' /$' | awk '{print $2}')
    SYSTEM_DEV="/dev/$SYSTEM_PART"
    log "Partition système détectée : $SYSTEM_DEV"
    zenity --info --window-icon="$ICON_PATH" --text="Partition système détectée : $SYSTEM_DEV"
}

function check_tools() {
    missing=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        zenity --info --window-icon="$ICON_PATH" --text="Installation des outils manquants : ${missing[*]}"
        if command -v apt &>/dev/null; then
            sudo apt update
            sudo apt install -y "${missing[@]}"
        else
            zenity --error --text="Gestionnaire de paquets non supporté. Abandon."
            exit 1
        fi
    fi
    detect_system_partition
}

############################################
# Fonctions utilitaires de listing de disques
############################################

# Affiche uniquement les disques amovibles (USB)
function list_disks_for_zenity() {
    lsblk -dno NAME,SIZE,MODEL,TYPE,RM | awk '$4 == "disk" && $5 == 1 { printf "/dev/%s (%s - %s)\n", $1, $2, $3 }'
}

# Affiche tous les disques (fixes + USB)
function list_all_disks_for_zenity() {
    lsblk -dno NAME,SIZE,MODEL,TYPE | awk '$4 == "disk" { printf "/dev/%s (%s - %s)\n", $1, $2, $3 }'
}

# Optionnel : pour afficher uniquement les disques USB à partir de la colonne TRAN (selon lsblk)
function list_usb_disks() {
    lsblk -d -o NAME,MODEL,SIZE,TRAN | grep -iw usb | awk '{print "/dev/"$1" - "$2" - "$3}'
}

############################################
# Fonctions principales d'opération
############################################

# Clonage d'un disque USB vers une image (.img) avec suivi de progression via pv
function clone_disk() {
    # Ici, on liste les disques amovibles
    mapfile -t disks < <(list_disks_for_zenity)
    if [ ${#disks[@]} -eq 0 ]; then
        zenity --error --text="Aucun disque USB détecté."
        return
    fi

    src=$(printf "%s\n" "${disks[@]}" | zenity --list \
        --title="Sélectionnez le disque source" \
        --column="Disques disponibles" \
        --width=700 --height=400)
    src_dev=$(echo "$src" | cut -d' ' -f1)
    [ -z "$src_dev" ] && return

    dest_file=$(zenity --file-selection --save --confirm-overwrite --title="Nom de l'image à créer (.img)")
    [ -z "$dest_file" ] && return
    # Ajout de l'extension .img si nécessaire
    [[ "$dest_file" != *.img ]] && dest_file="${dest_file}.img"

    disk_size=$(lsblk -bno SIZE "$src_dev")
    log "Clonage de $src_dev vers $dest_file"

    (
        sudo pv -s "$disk_size" "$src_dev" | sudo dd of="$dest_file" bs=4M conv=sync status=none
        echo 100
    ) | zenity --progress --title="Clonage en cours..." --percentage=0 --auto-close --width=400

    if [ $? -eq 0 ]; then
        zenity --info --text="Clonage terminé avec succès."
        verify_image_integrity "$dest_file"
        generate_pdf_report
    else
        zenity --error --text="Erreur lors du clonage du disque."
    fi
}

# Restauration d'une image (.img) sur un disque USB
function restore_image() {
    image_file=$(zenity --file-selection --title="Sélectionnez l'image à restaurer")
    [ -z "$image_file" ] && return

    mapfile -t disks < <(list_disks_for_zenity)
    dest=$(printf "%s\n" "${disks[@]}" | zenity --list \
        --title="Sélectionnez le disque de destination" \
        --column="Disques disponibles" \
        --width=700 --height=400)
    dest_dev=$(echo "$dest" | cut -d' ' -f1)
    [ -z "$dest_dev" ] && return

    log "Restauration de $image_file vers $dest_dev"
    image_size=$(stat -c %s "$image_file")
    (
        sudo pv -s "$image_size" "$image_file" | sudo dd of="$dest_dev" bs=4M conv=sync status=none
        echo 100
    ) | zenity --progress --title="Restauration en cours..." --percentage=0 --auto-close --width=400

    if [ $? -eq 0 ]; then
        zenity --info --text="Restauration terminée avec succès."
        verify_image_integrity "$image_file"
        generate_pdf_report
    else
        zenity --error --text="Erreur lors de la restauration."
    fi
}

# Vérification de l'intégrité d'une image avec SHA256
function verify_image_integrity() {
    image="$1"
    sha_file="$image.sha256"
    sha256sum "$image" > "$sha_file"
    if sha256sum -c "$sha_file"; then
        log "Intégrité de l'image vérifiée avec succès."
    else
        zenity --error --text="Échec de la vérification de l'intégrité de l'image."
        log "Échec de la vérification de l'intégrité."
    fi
}

# Vérification de l'intégrité de la restauration : compare la somme SHA256 de l'image source 
# avec celle calculée sur le disque restauré (lecture des mêmes octets)
function verify_restoration_integrity() {
    image="$1"
    target="$2"
    if [ -z "$image" ] || [ -z "$target" ]; then
        zenity --error --text="Fichier image et périphérique cible requis pour la vérification."
        return 1
    fi
    size=$(stat -c %s "$image")
    image_sha=$(sha256sum "$image" | awk '{print $1}')
    # Lire exactement le même nombre d'octets depuis le périphérique cible
    target_sha=$(sudo dd if="$target" bs=1M status=none | head -c "$size" | sha256sum | awk '{print $1}')
    if [ "$image_sha" = "$target_sha" ]; then
        log "La restauration a été vérifiée avec succès."
        zenity --info --text="La restauration a été vérifiée avec succès."
    else
        log "Échec de la vérification de la restauration."
        zenity --error --text="Échec de la vérification de la restauration."
    fi
}

# Fonction de comparaison disque/image (placeholder)
function compare_image_disk() {
    zenity --info --text="La fonction de comparaison disque/image n'est pas encore implémentée."
}

function view_pdf_reports() {
    xdg-open "$REPORT_DIR"
}

# Réduction d'une image disque (.img) et compression avec gzip
function reduce_image() {
    image_file=$(zenity --file-selection --title="Sélectionnez l'image à réduire")
    [ -z "$image_file" ] && return

    log "Réduction de l'image : $image_file"
    loopdev=$(sudo losetup --find --partscan --show "$image_file")
    if [ -z "$loopdev" ]; then
        zenity --error --text="Erreur lors de la création du périphérique loop."
        return
    fi
    part=$(lsblk -ln -o NAME "$loopdev" | sed -n 2p)
    if [ -z "$part" ]; then
        sudo losetup -d "$loopdev"
        zenity --error --text="Impossible de détecter la partition dans l'image."
        return
    fi
    part_dev="/dev/$part"
    (
        echo "0"
        sleep 1
        log "Vérification de la partition : $part_dev"
        sudo e2fsck -f "$part_dev" &>> "$LOG_FILE"
        echo "25"
        sleep 1
        log "Réduction du système de fichiers"
        sudo resize2fs -M "$part_dev" &>> "$LOG_FILE"
        echo "50"
        sleep 1
        sectors=$(sudo fdisk -l "$loopdev" | grep "^$part_dev" | awk '{print $3}')
        sector_size=$(sudo fdisk -l "$loopdev" | grep "Sector size" | awk -F'[: ]+' '{print $4}')
        if [ -z "$sectors" ] || [ -z "$sector_size" ]; then
            log "Erreur : impossible de déterminer la taille réelle de la partition"
            sudo losetup -d "$loopdev"
            zenity --error --text="Impossible de déterminer la nouvelle taille de l'image."
            return
        fi
        new_size=$(( (sectors + 2048) * sector_size ))
        log "Tronquage de l'image à $new_size octets"
        sudo losetup -d "$loopdev"
        truncate -s "$new_size" "$image_file"
        echo "100"
    ) | zenity --progress --title="Réduction de l'image" --percentage=0 --auto-close --width=400

    if [ $? -eq 0 ]; then
        zenity --info --text="Réduction terminée avec succès."
        log "Réduction de l'image terminée avec succès."
        generate_pdf_report
    else
        zenity --error --text="Erreur pendant la réduction de l'image."
    fi
}

# Affichage du message "À propos"
function about_popup() {
    local message="$(cat <<EOF
╭────────────────────────────╮
│     😺 PUSS IN BOOT 🥾     │
╰────────────────────────────╯

Programme développé par ChatGPT
avec l'aide précieuse de Cédric,
qui n'a fait que poser des questions au dev ;-)
EOF
)"
    (zenity --info --title="À propos" --text="$message" --timeout=20) &
}

# Nettoyage des fichiers temporaires
function cleanup_temp_files() {
    log "Nettoyage des fichiers temporaires..."
    sudo umount "$TMP_MOUNT" 2>/dev/null
    sudo losetup -D 2>/dev/null
    sudo rm -rf "$TMP_MOUNT"/*
    log "Fichiers temporaires nettoyés."
}

############################################
# Menu principal
############################################

function main_menu() {
    while true; do
        choice=$(zenity --list --title="Disk Image Tool" --width=600 --height=500 \
            --window-icon="$ICON_PATH" \
            --column="Option" --column="Description" \
            "📀 Cloner" "Cloner un disque vers une image (.img) avec suivi de progression" \
            "🧩 Restaurer" "Restaurer une image (.img) sur un disque USB" \
            "📉 Réduire" "Réduire une image .img et la compresser" \
            "🔍 Vérifier" "Vérifier l'intégrité SHA256 d'une image" \
            "🔒 Vérifier restauration" "Vérifier avec SHA256 le fichier .img et la restauration sur le disque" \
            "⚖️ Comparer" "Comparer un disque et une image" \
            "📂 Rapports" "Afficher les rapports PDF générés" \
            "📊 Statistiques" "Générer des statistiques des clonages" \
            "📡 Logs temps réel" "Afficher le journal d'opération en direct" \
            "🧰 Création" "Créer un .desktop ou une AppImage" \
            "📝 À propos" "Informations sur le programme" \
            "❌ Quitter" "Quitter l'application")
        case "$choice" in
            *Cloner*) clone_disk ;;
            *Restaurer*) restore_image ;;
            *Réduire*) reduce_image ;;
            *Vérifier*)
                image_file=$(zenity --file-selection --title="Sélectionnez une image à vérifier")
                [ -n "$image_file" ] && verify_image_integrity "$image_file" && generate_pdf_report
                ;;
            *Vérifier\ restauration*)
                image_file=$(zenity --file-selection --title="Sélectionnez l'image restaurée")
                target_dev=$(zenity --file-selection --directory --title="Sélectionnez le disque restauré")
                [ -n "$image_file" -a -n "$target_dev" ] && verify_restoration_integrity "$image_file" "$target_dev"
                ;;
            *Comparer*) compare_image_disk ;;
            *Rapports*) view_pdf_reports ;;  # Cette fonction doit être implémentée si nécessaire.
            *Statistiques*) generate_stats_plot ;;
            *Logs*) show_realtime_log ;;
            *Création*)
                subchoice=$(zenity --list --title="Choisissez une option" --column="Action" --column="Description" \
                    "1" "Créer un fichier .desktop" \
                    "2" "Créer une AppImage")
                case $subchoice in
                    1) create_desktop_entry ;;
                    2) create_appimage ;;
                esac
                ;;
            *propos*) about_popup ;;
            *Quitter*) cleanup_temp_files; exit 0 ;;
            *) break ;;
        esac
    done
}

check_tools
main_menu
