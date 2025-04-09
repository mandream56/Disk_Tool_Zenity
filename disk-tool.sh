
#!/bin/bash

LOG_FILE="$HOME/disk_tool.log"
REPORT_DIR="$HOME/disk_tool_reports"
TMP_MOUNT="/mnt/img_mount"
mkdir -p "$REPORT_DIR" "$TMP_MOUNT"
REQUIRED_TOOLS=(lsblk dd losetup mount umount parted fdisk truncate grep awk xargs sudo zenity gzip sha256sum cmp enscript ps2pdf xdg-open gnuplot tail appimagetool)

ICON_PATH="/usr/share/icons/gnome/48x48/devices/drive-harddisk.png"
PROGRESS_ICON="dialog-information"

function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# [... toutes les autres fonctions du script ...]

function cleanup_temp_files() {
    log "Nettoyage des fichiers temporaires..."
    if mountpoint -q "$TMP_MOUNT"; then
        sudo umount "$TMP_MOUNT"
        log "Point de montage démonté : $TMP_MOUNT"
    fi
    sudo rm -rf "$TMP_MOUNT"/*
    log "Contenu temporaire supprimé dans $TMP_MOUNT"
    rm -f "$REPORT_DIR/stats.dat"
    log "Fichiers statistiques supprimés"
    zenity --info --text="Nettoyage effectué avec succès."
}

function cleanup_and_exit() {
    cleanup_temp_files
    log "Fermeture de l'application."
    exit 0
}

function main_menu() {
    while true; do
        choice=$(zenity --list --title="Disk Image Tool" --width=500 --height=500             --window-icon="$ICON_PATH"             --column="Option" --column="Description"             "1" "Cloner un disque"             "2" "Restaurer une image"             "3" "Réduire une image"             "4" "Vérifier l'intégrité d'une image"             "5" "Comparer un disque et une image"             "6" "Voir les rapports PDF"             "7" "Afficher les statistiques/logs"             "8" "Suivi temps réel des opérations"             "9" "Créer un .desktop ou AppImage"             "10" "Générer un rapport PDF"             "11" "À propos"             "12" "Nettoyer les fichiers temporaires"             "13" "Quitter")

        case $choice in
            1) clone_disk ;;
            2) restore_image ;;
            3) reduce_image ;;
            4)
                image_file=$(zenity --file-selection --title="Sélectionnez une image à vérifier")
                [ -n "$image_file" ] && verify_image_integrity "$image_file" && generate_pdf_report
                ;;
            5) compare_image_disk ;;
            6) view_pdf_reports ;;
            7) generate_stats_plot ;;
            8) show_realtime_log ;;
            9)
                subchoice=$(zenity --list --title="Choisissez une option" --column="Action" --column="Description"                     "1" "Créer un fichier .desktop"                     "2" "Créer une AppImage")
                case $subchoice in
                    1) create_desktop_entry ;;
                    2) create_appimage ;;
                esac
                ;;
            10) generate_pdf_report ;;
            11) show_about ;;
            12) cleanup_temp_files ;;
            13) cleanup_and_exit ;;
            *) break ;;
        esac
    done
}

check_tools
main_menu


function show_about() {
    about_text="  /\\_/\\  
 ( o.o )   Le Chat Potté vous salue !
  > ^ <

Programme développé par ChatGPT avec l’aide précieuse de Cédric
(qui n’a fait que poser des questions au dev 😉)"

    timeout 20 zenity --info \
        --title=\"À propos de Disk Tool\" \
        --width=400 \
        --height=250 \
        --window-icon=\"$ICON_PATH\" \
        --text=\"$about_text\" &
}

