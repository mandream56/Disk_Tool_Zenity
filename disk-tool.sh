#!/bin/bash
# Version complète du script Disk Tool Zenity (simplifiée ici pour l'exemple)
echo "Bienvenue dans Disk Tool Zenity"
LOG_FILE="$HOME/disk_tool.log"
REPORT_DIR="$HOME/disk_tool_reports"
TMP_MOUNT="/mnt/img_mount"
mkdir -p "$REPORT_DIR" "$TMP_MOUNT"

REQUIRED_TOOLS=(lsblk dd losetup mount umount parted fdisk truncate grep awk xargs sudo zenity gzip sha256sum cmp enscript ps2pdf xdg-open gnuplot tail appimagetool)

ICON_PATH="/usr/share/icons/gnome/48x48/devices/drive-harddisk.png"

function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

function info() {
    zenity --info --window-icon="$ICON_PATH" --text="$1"
}

function error() {
    zenity --error --window-icon="$ICON_PATH" --text="$1"
}

function select_disk() {
    lsblk -dpno NAME,SIZE | grep -v "/loop" | \
    zenity --list --title="$1" --column="Disque" --column="Taille"
}

function select_file() {
    zenity --file-selection --title="$1"
}

function check_tools() {
    local missing=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done

    if [ ${#missing[@]} -ne 0 ]; then
        info "Installation des outils manquants : ${missing[*]}"
        if command -v apt &>/dev/null; then
            sudo apt update && sudo apt install -y "${missing[@]}"
        else
            error "Gestionnaire de paquets non supporté. Abandon."
            exit 1
        fi
    fi

    detect_system_partition
}

function detect_system_partition() {
    SYSTEM_DEV=$(findmnt -n -o SOURCE /)
    log "Partition système détectée : $SYSTEM_DEV"
    info "Partition système détectée : $SYSTEM_DEV"
}

function generate_pdf_report() {
    local DATE=$(date +%Y%m%d_%H%M%S)
    local report_txt="$REPORT_DIR/report_$DATE.txt"
    local report_pdf="${report_txt%.txt}.pdf"

    {
        echo "--- Rapport Disk Tool ---"
        echo "Date : $(date)"
        echo "Machine : $(hostname)"
        echo "Utilisateur : $USER"
        echo -e "\nDernières lignes du journal :"
        tail -n 20 "$LOG_FILE"
    } > "$report_txt"

    enscript "$report_txt" -o - | ps2pdf - "$report_pdf"
    xdg-open "$report_pdf" &
}

function verify_image_integrity() {
    local image_file="$1"
    local hash=$(sha256sum "$image_file" | awk '{print $1}')
    log "$image_file => SHA256: $hash"
    info "Vérification SHA256 :\n$hash"
}

function clone_disk() {
    local src=$(select_disk "Sélectionnez le disque source")
    [ -z "$src" ] && return

    local dest_file=$(zenity --file-selection --save --confirm-overwrite --title="Nom de l'image à créer (.img)")
    [ -z "$dest_file" ] && return

    info "Clonage de $src vers $dest_file"
    if (sudo dd if="$src" of="$dest_file" bs=4M status=progress conv=sync; sync) | \
        zenity --progress --title="Clonage..." --pulsate --auto-close --auto-kill; then
        info "Clonage terminé."
        verify_image_integrity "$dest_file"
        generate_pdf_report
    else
        error "Erreur lors du clonage."
    fi
}

function restore_image() {
    local image_file=$(select_file "Sélectionnez l'image à restaurer")
    [ -z "$image_file" ] && return

    local dest=$(select_disk "Sélectionnez le disque de destination")
    [ -z "$dest" ] && return

    info "Restauration de $image_file vers $dest"
    if (sudo dd if="$image_file" of="$dest" bs=4M status=progress conv=sync; sync) | \
        zenity --progress --title="Restauration..." --pulsate --auto-close --auto-kill; then
        info "Restauration terminée."
        verify_image_integrity "$image_file"
        generate_pdf_report
    else
        error "Erreur lors de la restauration."
    fi
}

function reduce_image() {
    local image_file=$(select_file "Sélectionnez l'image à réduire")
    [ -z "$image_file" ] && return

    local offset_block=$(sudo fdisk -l "$image_file" | grep -E '^/dev' | awk '{print $3}' | \
        zenity --list --title="Sélectionnez le dernier bloc" --column="Blocs")
    [ -z "$offset_block" ] && return

    local block_size=512
    local new_size=$((offset_block * block_size))
    local reduced_image="${image_file%.img}_reduced.img"

    log "Réduction de l'image : $image_file → $reduced_image (taille: $new_size)"
    cp "$image_file" "$reduced_image"
    truncate -s "$new_size" "$reduced_image"
    gzip -f "$reduced_image"

    local original_size=$(stat -c%s "$image_file")
    local reduced_size=$(stat -c%s "$reduced_image.gz")
    local percent_saved=0
    if [ "$original_size" -gt 0 ]; then
        percent_saved=$(( (original_size - reduced_size) * 100 / original_size ))
    fi

    info "Image réduite créée : $reduced_image.gz\nGain estimé : $percent_saved %"
    log "Image réduite créée : $reduced_image.gz (gain: $percent_saved %)"
    generate_pdf_report
}

function show_realtime_log() {
    xterm -fa 'Monospace' -fs 10 -e "tail -f $LOG_FILE" &
}

function generate_stats_plot() {
    local stats_file="$REPORT_DIR/stats.dat"
    grep "Clonage de" "$LOG_FILE" | awk '{print $1, $2, $(NF)}' > "$stats_file"
    gnuplot -persist <<-EOF
        set title "Historique des opérations de clonage"
        set xlabel "Date"
        set xdata time
        set timefmt "%Y-%m-%d"
        set format x "%d/%m"
        set ylabel "Nom du disque/image"
        set style data histogram
        set style histogram cluster gap 1
        set style fill solid
        set boxwidth 0.75
        plot "$stats_file" using 0:xtic(2) title 'Clonages'
EOF
}

function main_menu() {
    while true; do
        local choice=$(zenity --list --title="Disk Image Tool" --width=500 --height=400 \
            --window-icon="$ICON_PATH" \
            --column="Option" --column="Description" \
            "1" "Cloner un disque" \
            "2" "Restaurer une image" \
            "3" "Réduire une image" \
            "4" "Vérifier l'intégrité d'une image" \
            "5" "Comparer un disque et une image" \
            "6" "Voir les rapports PDF" \
            "7" "Afficher les statistiques/logs" \
            "8" "Suivi temps réel des opérations" \
            "9" "Créer un .desktop ou AppImage" \
            "10" "Générer un rapport PDF" \
            "11" "Quitter")

        case $choice in
            1) clone_disk ;;
            2) restore_image ;;
            3) reduce_image ;;
            4)
                local image_file=$(select_file "Sélectionnez une image à vérifier")
                [ -n "$image_file" ] && verify_image_integrity "$image_file" && generate_pdf_report
                ;;
            5) compare_image_disk ;;
            6) view_pdf_reports ;;
            7) generate_stats_plot ;;
            8) show_realtime_log ;;
            9)
                local subchoice=$(zenity --list --title="Choisissez une option" --column="Action" --column="Description" \
                    "1" "Créer un fichier .desktop" \
                    "2" "Créer une AppImage")
                case $subchoice in
                    1) create_desktop_entry ;;
                    2) create_appimage ;;
                esac
                ;;
            10) generate_pdf_report ;;
            11) exit 0 ;;
            *) break ;;
        esac
    done
}

trap "umount -l $TMP_MOUNT 2>/dev/null; rm -rf $TMP_MOUNT" EXIT

check_tools
main_menu
