#!/usr/bin/env bash
# Hyprland Components Installer — EndeavourOS / Arch Linux
# Adds desktop components around an already-installed Hyprland 0.54.3 stack.
# It DOES NOT install or upgrade Hyprland itself. It deliberately avoids pacman -Syu.
# Run as the regular target user, NOT with sudo: bash install-hyprland-components.sh

set -uo pipefail
IFS=$'\n\t'

VERSION="1.0.1"
SCRIPT_NAME="hyprland-components-installer"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hyprland-components"
RUN_DIR="$STATE_DIR/runs/$STAMP"
BACKUP_DIR="$STATE_DIR/backups/$STAMP"
LOG_FILE="$RUN_DIR/install.log"
REPORT_FILE="$RUN_DIR/report.txt"
MANIFEST_FILE="$BACKUP_DIR/manifest.tsv"

DRY_RUN=0
SKIP_CONFIG=0
YES=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-config) SKIP_CONFIG=1 ;;
    --yes) YES=1 ;;
    --help|-h)
      cat <<'EOF'
Usage: bash install-hyprland-components.sh [--dry-run] [--skip-config] [--yes]

  --dry-run      Preview package plans only; do not install packages or edit configs.
  --skip-config  Install packages/services only; do not create/edit user configs.
  --yes          Skip the initial whole-script confirmation. Pacman still asks for each transaction.

Run as your normal user (never with sudo). The script deliberately does not run
pacman -Syu, does not force transactions, and blocks package transactions that
include the protected Hyprland stack. Read the report at the end.
EOF
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  echo "ERREUR: lance ce script en utilisateur normal, pas avec sudo." >&2
  echo "Exemple: bash install-hyprland-components.sh" >&2
  exit 2
fi

if [[ ! -r /etc/os-release ]] || ! grep -Eiq '^(ID|ID_LIKE)=.*(arch|endeavour)' /etc/os-release; then
  echo "ERREUR: ce script est prévu pour EndeavourOS / Arch Linux." >&2
  exit 2
fi

command -v pacman >/dev/null 2>&1 || { echo "ERREUR: pacman introuvable." >&2; exit 2; }
command -v sudo >/dev/null 2>&1 || { echo "ERREUR: sudo est nécessaire pour les opérations système." >&2; exit 2; }

mkdir -p "$RUN_DIR" "$BACKUP_DIR"
: > "$MANIFEST_FILE"
: > "$RUN_DIR/skipped.tsv"
: > "$RUN_DIR/failed.tsv"
: > "$RUN_DIR/installed.tsv"
: > "$RUN_DIR/configured.tsv"
: > "$RUN_DIR/notes.txt"
chmod 700 "$RUN_DIR" "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

say()  { printf '\n\033[1;36m[%s]\033[0m %s\n' "$SCRIPT_NAME" "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[AVERTISSEMENT]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*"; }
record(){ printf '%s\t%s\n' "$1" "$2" >> "$3"; }

# Versions the user explicitly asked to preserve. Any appearance in a planned
# package transaction blocks that transaction, regardless of the version shown.
PROTECTED_PACKAGES=(
  hyprland aquamarine hyprutils hyprgraphics hyprcursor hyprlang hyprtoolkit
  hyprwire hyprland-guiutils hyprwayland-scanner libjxl
)
# Historical versions provided by the user; used for an audit report only.
declare -A EXPECTED_VERSIONS=(
  [hyprland]='0.54.3-2'
  [aquamarine]='0.10.0-4'
  [hyprutils]='0.12.0-1'
  [hyprgraphics]='0.5.1-1'
  [hyprcursor]='0.1.13-5'
  [hyprlang]='0.6.8-3'
  [hyprtoolkit]='0.5.3-2'
  [hyprwire]='0.3.0-2'
  [hyprland-guiutils]='0.2.1-3'
  [hyprwayland-scanner]='0.4.5-1'
  [libjxl]='0.11.2-2'
)

is_protected() {
  local target="$1" p
  target="${target#*/}"
  for p in "${PROTECTED_PACKAGES[@]}"; do
    [[ "$target" == "$p" ]] && return 0
  done
  return 1
}

# Back up existing files only when the script is about to modify them.
backup_user_file() {
  local file="$1" rel dest
  if [[ -e "$file" || -L "$file" ]]; then
    if [[ "$file" == "$HOME/"* ]]; then
      rel="${file#"$HOME"/}"
    else
      rel="${file#/}"
    fi
    dest="$BACKUP_DIR/files/home/$rel"
    mkdir -p "$(dirname "$dest")"
    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
      cp -a -- "$file" "$dest" || return 1
      printf 'EXISTING\t%s\t%s\n' "$file" "$dest" >> "$MANIFEST_FILE"
      ok "Sauvegarde: $file"
    fi
  else
    printf 'NEW\t%s\t-\n' "$file" >> "$MANIFEST_FILE"
  fi
}

backup_system_file() {
  local file="$1" rel dest
  if sudo test -e "$file" || sudo test -L "$file"; then
    rel="${file#/}"
    dest="$BACKUP_DIR/files/system/$rel"
    mkdir -p "$(dirname "$dest")"
    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
      sudo cp -a -- "$file" "$dest" || return 1
      sudo chown -R "$(id -u):$(id -g)" "$BACKUP_DIR/files/system" 2>/dev/null || true
      printf 'EXISTING_SYSTEM\t%s\t%s\n' "$file" "$dest" >> "$MANIFEST_FILE"
      ok "Sauvegarde système: $file"
    fi
  else
    printf 'NEW_SYSTEM\t%s\t-\n' "$file" >> "$MANIFEST_FILE"
  fi
}

# Replace only a named managed block; preserve all unrelated lines.
# Marker syntax is selectable because INI, Vim, JSONC and CSS have different comment forms.
write_user_block_custom() {
  local file="$1" id="$2" begin="$3" end="$4" body="$5" tmp bcount=0 ecount=0
  mkdir -p "$(dirname "$file")"
  backup_user_file "$file" || return 1
  # A half-present marker could make a block replacement consume unrelated lines.
  # Refuse that file rather than risk deleting user content.
  if [[ -f "$file" ]]; then
    bcount=$(grep -Fxc -- "$begin" "$file" 2>/dev/null || true)
    ecount=$(grep -Fxc -- "$end" "$file" 2>/dev/null || true)
    if [[ "$bcount" != "$ecount" ]] || (( bcount > 1 || ecount > 1 )); then
      warn "Marqueurs incohérents dans $file; fichier laissé inchangé ($id)."
      record "BLOCK_NOT_WRITTEN" "$file:MARKERS_INCONSISTENT:$id" "$RUN_DIR/skipped.tsv"
      return 1
    fi
  fi
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$file" > "$tmp"
  fi
  {
    [[ -s "$tmp" ]] && { cat "$tmp"; printf '\n'; }
    printf '%s\n' "$begin"
    cat "$body"
    printf '%s\n' "$end"
  } > "$tmp.new"
  mv "$tmp.new" "$file"
  chmod 600 "$file" 2>/dev/null || true
  rm -f "$tmp"
  record "UPDATED" "$file" "$RUN_DIR/configured.tsv"
  ok "Bloc géré mis à jour: $file ($id)"
}

write_user_block() {
  local id="$2"
  write_user_block_custom "$1" "$id" \
    "# >>> MANAGED BY HYPRLAND COMPONENTS: $id >>>" \
    "# <<< END HYPRLAND COMPONENTS: $id <<<" "$3"
}

write_user_block_jsonc() {
  local id="$2"
  write_user_block_custom "$1" "$id" \
    "// >>> MANAGED BY HYPRLAND COMPONENTS: $id >>>" \
    "// <<< END HYPRLAND COMPONENTS: $id <<<" "$3"
}

write_user_block_css() {
  local id="$2"
  write_user_block_custom "$1" "$id" \
    "/* >>> MANAGED BY HYPRLAND COMPONENTS: $id >>> */" \
    "/* <<< END HYPRLAND COMPONENTS: $id <<< */" "$3"
}

write_user_block_vim() {
  local id="$2"
  write_user_block_custom "$1" "$id" \
    "\" >>> MANAGED BY HYPRLAND COMPONENTS: $id >>>" \
    "\" <<< END HYPRLAND COMPONENTS: $id <<<" "$3"
}

replace_user_file() {
  local file="$1" src="$2"
  mkdir -p "$(dirname "$file")"
  backup_user_file "$file" || return 1
  install -m 600 "$src" "$file"
  record "REPLACED" "$file" "$RUN_DIR/configured.tsv"
  ok "Remplacé après sauvegarde: $file"
}

write_user_file_if_missing() {
  local file="$1" src="$2" mode="${3:-600}"
  mkdir -p "$(dirname "$file")"
  if [[ -e "$file" || -L "$file" ]]; then
    warn "Conservé sans modification (déjà présent): $file"
    record "KEPT_EXISTING" "$file" "$RUN_DIR/configured.tsv"
    return 0
  fi
  printf 'NEW\t%s\t-\n' "$file" >> "$MANIFEST_FILE"
  install -m "$mode" "$src" "$file"
  record "CREATED" "$file" "$RUN_DIR/configured.tsv"
  ok "Créé: $file"
}

# Strict package transaction preview. Pacman resolves dependencies in print mode;
# if preview fails or any protected package is present, no install is attempted.
install_group() {
  local label="$1"; shift
  local -a pkgs=("$@")
  local preview status line token pkg version
  ((${#pkgs[@]})) || return 0
  say "Paquets: $label"
  printf 'Cibles: %s\n' "${pkgs[*]}"
  if (( DRY_RUN )); then
    preview="$(sudo pacman -S --needed --print-format '%n %v' "${pkgs[@]}" 2>&1)"
    status=$?
    printf '%s\n' "$preview"
    if (( status != 0 )); then
      warn "Aperçu impossible; transaction bloquée: $label"
      record "$label" "PREVIEW_FAILED" "$RUN_DIR/skipped.tsv"
      return 1
    fi
    if printf '%s\n' "$preview" | grep -Eiq '(^|[[:space:]/])(hyprland|aquamarine|hyprutils|hyprgraphics|hyprcursor|hyprlang|hyprtoolkit|hyprwire|hyprland-guiutils|hyprwayland-scanner|libjxl)([[:space:]/]|$)'; then
      warn "Aperçu contenant un paquet protégé: $label — transaction bloquée."
      record "$label" "PROTECTED_PACKAGE_IN_PREVIEW" "$RUN_DIR/skipped.tsv"
      return 1
    fi
    ok "Aperçu seulement; aucune installation (--dry-run)."
    record "$label" "DRY_RUN_PREVIEW" "$RUN_DIR/installed.tsv"
    return 0
  fi

  preview="$(sudo pacman -S --needed --print-format '%n %v' "${pkgs[@]}" 2>&1)"
  status=$?
  printf '%s\n' "$preview"
  if (( status != 0 )); then
    warn "La résolution des dépendances a échoué; groupe ignoré: $label"
    record "$label" "DEPENDENCY_RESOLUTION_FAILED" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  # Parse pacman-formatted lines only; false-positive text is harmless because it blocks.
  while IFS=' ' read -r pkg version _; do
    [[ -z "${pkg:-}" ]] && continue
    pkg="${pkg#*/}"
    if is_protected "$pkg"; then
      err "Transaction bloquée: le plan contient un paquet protégé ($pkg $version)."
      record "$label" "PROTECTED:$pkg:$version" "$RUN_DIR/skipped.tsv"
      return 1
    fi
  done <<< "$preview"

  warn "Pacman va afficher sa transaction réelle. Lis les paquets et refuse toute suppression/remplacement inattendu."
  if sudo pacman -S --needed "${pkgs[@]}"; then
    ok "Groupe installé: $label"
    record "$label" "INSTALLED_OR_ALREADY_PRESENT" "$RUN_DIR/installed.tsv"
    return 0
  fi
  warn "Installation en échec ou annulée; poursuite avec les groupes indépendants: $label"
  record "$label" "INSTALL_FAILED_OR_CANCELLED" "$RUN_DIR/failed.tsv"
  return 1
}

# Service helpers deliberately avoid replacing an existing display/network/firewall manager.
service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
service_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

start_networkmanager_safely() {
  command -v NetworkManager >/dev/null 2>&1 || true
  if service_active NetworkManager.service; then
    ok "NetworkManager est déjà actif."
    return 0
  fi
  if service_active systemd-networkd.service || service_active iwd.service; then
    warn "systemd-networkd ou iwd est actif; NetworkManager ne sera pas activé automatiquement. Vérifie les gestionnaires réseau manuellement."
    record "NetworkManager" "SKIPPED_COMPETING_NETWORK_SERVICE" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    warn "Session SSH détectée: pas de bascule automatique du réseau."
    record "NetworkManager" "SKIPPED_REMOTE_SESSION" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if sudo systemctl enable --now NetworkManager.service; then
    ok "NetworkManager activé."
    return 0
  fi
  record "NetworkManager" "SERVICE_ENABLE_FAILED" "$RUN_DIR/failed.tsv"
  return 1
}

enable_bluetooth_safely() {
  if service_active bluetooth.service; then ok "Bluetooth déjà actif."; return 0; fi
  if sudo systemctl enable --now bluetooth.service; then ok "Bluetooth activé."; else record "bluetooth.service" "ENABLE_FAILED" "$RUN_DIR/failed.tsv"; fi
}

enable_firewalld_safely() {
  if service_active firewalld.service; then
    ok "Firewalld est déjà actif; règles existantes laissées intactes."
    return 0
  fi
  if service_active ufw.service || service_active nftables.service; then
    warn "Un autre service pare-feu semble actif; Firewalld ne sera pas activé pour éviter les règles concurrentes."
    record "firewalld" "SKIPPED_COMPETING_FIREWALL" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    warn "Session SSH détectée: Firewalld sera installé mais pas activé automatiquement."
    record "firewalld" "SKIPPED_REMOTE_SESSION" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if sudo systemctl enable --now firewalld.service; then
    # Back up any existing public-zone file before changing permanent policy.
    if command -v firewall-cmd >/dev/null 2>&1; then
      backup_system_file /etc/firewalld/zones/public.xml || true
      # Do not add inbound services; remove SSH only from the newly configured public zone.
      sudo firewall-cmd --permanent --zone=public --remove-service=ssh >/dev/null 2>&1 || true
      sudo firewall-cmd --reload >/dev/null 2>&1 || true
      ok "Firewalld activé; service SSH entrant non ajouté par ce script."
    fi
  else
    record "firewalld" "ENABLE_FAILED" "$RUN_DIR/failed.tsv"
  fi
}

enable_power_profiles_safely() {
  local svc
  for svc in tlp.service tuned.service auto-cpufreq.service system76-power.service; do
    if service_active "$svc" || service_enabled "$svc"; then
      warn "$svc est présent/actif; power-profiles-daemon ne sera pas activé pour éviter les conflits."
      record "power-profiles-daemon" "SKIPPED_CONFLICT:$svc" "$RUN_DIR/skipped.tsv"
      return 1
    fi
  done
  if sudo systemctl enable --now power-profiles-daemon.service; then
    ok "power-profiles-daemon activé."
  else
    record "power-profiles-daemon" "ENABLE_FAILED" "$RUN_DIR/failed.tsv"
  fi
}

enable_sddm_safely() {
  local current_dm=""
  if [[ -L /etc/systemd/system/display-manager.service ]]; then
    current_dm="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)" 2>/dev/null || true)"
  fi
  if [[ "$current_dm" == "sddm.service" || "$current_dm" == "sddm" ]]; then
    ok "SDDM est déjà le display manager sélectionné."
    return 0
  fi
  if [[ -n "$current_dm" ]] || service_enabled display-manager.service; then
    warn "Un display manager existe déjà ($current_dm); SDDM ne prendra pas sa place automatiquement."
    record "sddm.service" "SKIPPED_EXISTING_DISPLAY_MANAGER:$current_dm" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    warn "Session SSH détectée: SDDM ne sera pas activé à distance."
    record "sddm.service" "SKIPPED_REMOTE_SESSION" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if sudo systemctl enable sddm.service; then
    ok "SDDM configuré pour le prochain démarrage (pas de bascule immédiate)."
  else
    record "sddm.service" "ENABLE_FAILED" "$RUN_DIR/failed.tsv"
  fi
}

install_yay_if_missing() {
  if command -v yay >/dev/null 2>&1; then
    ok "Yay est déjà installé."
    return 0
  fi
  if (( DRY_RUN )); then
    say "--dry-run: Yay absent; aucune compilation AUR effectuée."
    record "yay" "DRY_RUN_NOT_BUILT" "$RUN_DIR/skipped.tsv"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1 || ! command -v makepkg >/dev/null 2>&1; then
    warn "Yay absent et Git/makepkg indisponibles; installation AUR ignorée."
    record "yay" "MISSING_GIT_OR_MAKEPKG" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if ! ask_yes_no "Yay est absent. Cloner son PKGBUILD AUR et le construire en utilisateur normal ?" yes; then
    record "yay" "DECLINED" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  local builddir="$HOME/.cache/$SCRIPT_NAME/yay-build-$STAMP"
  mkdir -p "$(dirname "$builddir")"
  if git clone https://aur.archlinux.org/yay.git "$builddir" && (cd "$builddir" && makepkg -si); then
    ok "Yay installé."
    record "yay" "INSTALLED_FROM_AUR" "$RUN_DIR/installed.tsv"
  else
    warn "La construction de Yay a échoué; les étapes AUR seront ignorées."
    record "yay" "BUILD_FAILED" "$RUN_DIR/failed.tsv"
  fi
}

ask_yes_no() {
  local prompt="$1" default="${2:-no}" ans
  if [[ "$default" == "yes" ]]; then prompt="$prompt [O/n] "; else prompt="$prompt [o/N] "; fi
  read -r -p "$prompt" ans || return 1
  ans="${ans,,}"
  if [[ -z "$ans" ]]; then [[ "$default" == "yes" ]]; return; fi
  [[ "$ans" == "o" || "$ans" == "oui" || "$ans" == "y" || "$ans" == "yes" ]]
}

install_aur_component_safely() {
  local pkg="$1" label="$2" preview status found=0 line tok
  if ! command -v yay >/dev/null 2>&1; then
    warn "Yay absent: composant AUR ignoré: $label"
    record "$label" "SKIPPED_YAY_NOT_INSTALLED" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if pacman -Qq "$pkg" >/dev/null 2>&1; then
    ok "$label est déjà installé."
    return 0
  fi
  if (( DRY_RUN )); then
    preview="$(yay -S --needed --print-format '%n %v' "$pkg" 2>&1)"
    status=$?
    printf '%s\n' "$preview"
    if (( status != 0 )); then record "$label" "AUR_PREVIEW_FAILED" "$RUN_DIR/skipped.tsv"; return 1; fi
    if printf '%s\n' "$preview" | grep -Eiq '(^|[[:space:]/])(hyprland|aquamarine|hyprutils|hyprgraphics|hyprcursor|hyprlang|hyprtoolkit|hyprwire|hyprland-guiutils|hyprwayland-scanner|libjxl)([[:space:]/]|$)'; then
      warn "AUR preview includes a protected package; blocked: $label"
      record "$label" "PROTECTED_IN_AUR_PREVIEW" "$RUN_DIR/skipped.tsv"
      return 1
    fi
    record "$label" "AUR_DRY_RUN" "$RUN_DIR/installed.tsv"
    return 0
  fi
  preview="$(yay -S --needed --print-format '%n %v' "$pkg" 2>&1)"
  status=$?
  printf '%s\n' "$preview"
  if (( status != 0 )); then
    warn "AUR preview failed; component blocked: $label"
    record "$label" "AUR_PREVIEW_FAILED" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if printf '%s\n' "$preview" | grep -Eiq '(^|[[:space:]/])(hyprland|aquamarine|hyprutils|hyprgraphics|hyprcursor|hyprlang|hyprtoolkit|hyprwire|hyprland-guiutils|hyprwayland-scanner|libjxl)([[:space:]/]|$)'; then
    warn "AUR preview includes a protected package; component blocked: $label"
    record "$label" "PROTECTED_IN_AUR_PREVIEW" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if ! ask_yes_no "Installer le paquet AUR $pkg ? Lis attentivement les PKGBUILD et la transaction." no; then
    record "$label" "DECLINED" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  if yay -S --needed "$pkg"; then
    ok "$label installé."
    record "$label" "INSTALLED_FROM_AUR" "$RUN_DIR/installed.tsv"
  else
    warn "Échec installation AUR: $label"
    record "$label" "INSTALL_FAILED" "$RUN_DIR/failed.tsv"
  fi
}

# Creates a monochrome nebula wallpaper using only Python's standard library.
# Does not overwrite an existing image.
generate_wallpaper() {
  local out="$HOME/Pictures/Wallpapers/glass-cosmos.png"
  mkdir -p "$(dirname "$out")"
  if [[ -e "$out" ]]; then
    ok "Fond d'écran existant conservé: $out"
    printf '%s\n' "$out"
    return 0
  fi
  if (( DRY_RUN )); then
    say "--dry-run: un fond cosmique PNG serait généré dans $out"
    printf '%s\n' "$out"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "Python indisponible pour générer le fond cosmique; le fond sera laissé sans génération."
    record "cosmic-wallpaper" "PYTHON_NOT_FOUND" "$RUN_DIR/skipped.tsv"
    printf '%s\n' "$out"
    return 1
  fi
  python3 - "$out" <<'PY'
import math, random, struct, sys, zlib
from pathlib import Path
out = Path(sys.argv[1])
W, H = 1600, 900
rng = random.Random(5403)
# Elliptical monochrome nebulae: x-center, y-center, x-radius, y-radius, brightness.
clouds = [
    (0.25, 0.42, 0.20, 0.13, 42),
    (0.36, 0.47, 0.27, 0.10, 32),
    (0.70, 0.30, 0.18, 0.12, 36),
    (0.79, 0.58, 0.24, 0.16, 28),
    (0.53, 0.68, 0.22, 0.08, 18),
    (0.11, 0.77, 0.16, 0.10, 15),
]
# Sparse, sharp stars (some brighter than others).
stars = {}
for _ in range(1600):
    x, y = rng.randrange(W), rng.randrange(H)
    stars[(x, y)] = rng.choice((75, 100, 135, 190, 230, 255))
row_bytes = bytearray()
for y in range(H):
    row_bytes.append(0)  # PNG filter: None
    yn = y / H
    for x in range(W):
        xn = x / W
        # Deep charcoal base with a subtle vertical vignette.
        intensity = 4.5 + 4.5 * (1.0 - abs(yn - 0.46) / 0.70)
        for cx, cy, rx, ry, amp in clouds:
            dx = (xn - cx) / rx
            dy = (yn - cy) / ry
            q = dx*dx + dy*dy
            if q < 8.0:
                intensity += amp * math.exp(-2.1 * q)
        # Long faint cloudy band to add a distant nebula feel.
        band = (yn - (0.28 + 0.20*xn + 0.025*math.sin(xn*15))) / 0.06
        intensity += 10.0 * math.exp(-0.5 * band*band) * (0.35 + 0.65 * math.sin(xn*17+1.2)**2)
        intensity += rng.random() * 4.2 - 2.1
        if (x, y) in stars:
            intensity = max(intensity, stars[(x, y)])
        g = max(0, min(255, int(intensity)))
        row_bytes.extend((g, g, g))
def chunk(tag, data):
    return struct.pack('!I', len(data)) + tag + data + struct.pack('!I', zlib.crc32(tag + data) & 0xffffffff)
raw = b'\x89PNG\r\n\x1a\n'
raw += chunk(b'IHDR', struct.pack('!2I5B', W, H, 8, 2, 0, 0, 0))
raw += chunk(b'IDAT', zlib.compress(bytes(row_bytes), 7))
raw += chunk(b'IEND', b'')
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(raw)
PY
  if [[ -s "$out" ]]; then
    chmod 644 "$out"
    ok "Fond cosmique généré: $out"
    record "cosmic-wallpaper" "GENERATED:$out" "$RUN_DIR/configured.tsv"
  else
    warn "La génération du fond cosmique n'a pas créé de fichier valide."
  fi
  printf '%s\n' "$out"
}

write_helper_scripts() {
  local bindir="$HOME/.local/bin"
  mkdir -p "$bindir"

  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -u
OUT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/Screenshot-$STAMP.png"
GEOMETRY="$(slurp 2>/dev/null)" || exit 0
[[ -n "$GEOMETRY" ]] || exit 0
TMP="$(mktemp --suffix=.png)"
trap 'rm -f "$TMP"' EXIT
if ! grim -g "$GEOMETRY" "$TMP"; then
  notify-send "Capture échouée" "grim n'a pas pu capturer la zone." 2>/dev/null || true
  exit 1
fi
if command -v swappy >/dev/null 2>&1; then
  swappy -f "$TMP" -o "$OUT"
else
  cp -n "$TMP" "$OUT"
fi
[[ -e "$OUT" ]] && notify-send "Capture enregistrée" "$OUT" 2>/dev/null || true
EOF
  write_user_file_if_missing "$bindir/hyprland-screenshot" "$tmp" 700
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -u
OUT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/Screenshot-full-$STAMP.png"
TMP="$(mktemp --suffix=.png)"
trap 'rm -f "$TMP"' EXIT
if ! grim "$TMP"; then
  notify-send "Capture échouée" "grim n'a pas pu capturer l'écran." 2>/dev/null || true
  exit 1
fi
if command -v swappy >/dev/null 2>&1; then
  swappy -f "$TMP" -o "$OUT"
else
  cp -n "$TMP" "$OUT"
fi
[[ -e "$OUT" ]] && notify-send "Capture enregistrée" "$OUT" 2>/dev/null || true
EOF
  write_user_file_if_missing "$bindir/hyprland-screenshot-full" "$tmp" 700
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -u
OUT_DIR="$HOME/Videos/Recordings"
mkdir -p "$OUT_DIR"
command -v wf-recorder >/dev/null 2>&1 || { notify-send "Enregistreur indisponible" "wf-recorder n'est pas installé." 2>/dev/null || true; exit 1; }
command -v tofi >/dev/null 2>&1 || exit 1
MODE="$(printf 'Plein écran\nZone sélectionnée' | tofi --prompt-text 'Zone')" || exit 0
[[ -n "$MODE" ]] || exit 0
ARGS=()
if [[ "$MODE" == "Zone sélectionnée" ]]; then
  GEOMETRY="$(slurp 2>/dev/null)" || exit 0
  [[ -n "$GEOMETRY" ]] || exit 0
  ARGS+=(--geometry "$GEOMETRY")
fi
AUDIO="$(printf 'Vidéo seule\nVidéo + audio' | tofi --prompt-text 'Audio')" || exit 0
[[ -n "$AUDIO" ]] || exit 0
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/Recording-$STAMP.mkv"
if [[ "$AUDIO" == "Vidéo + audio" ]]; then
  notify-send "Enregistrement" "Une fenêtre Kitty contrôle l'enregistrement. Clique dedans puis CTRL+C pour arrêter." 2>/dev/null || true
  kitty --title "RECORDING // CTRL+C TO STOP" wf-recorder "${ARGS[@]}" --audio -f "$OUT"
else
  notify-send "Enregistrement" "Une fenêtre Kitty contrôle l'enregistrement. Clique dedans puis CTRL+C pour arrêter." 2>/dev/null || true
  kitty --title "RECORDING // CTRL+C TO STOP" wf-recorder "${ARGS[@]}" -f "$OUT"
fi
EOF
  write_user_file_if_missing "$bindir/hyprland-record" "$tmp" 700
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -u
if pgrep -x hyprlock >/dev/null 2>&1; then exit 0; fi
# The requested privacy rule: clear Cliphist history before locking.
if command -v cliphist >/dev/null 2>&1; then cliphist wipe >/dev/null 2>&1 || true; fi
exec hyprlock
EOF
  write_user_file_if_missing "$bindir/hyprland-lock" "$tmp" 700
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -u
action="${1:-}"
case "$action" in
  poweroff) label="Éteindre l'ordinateur" ;;
  reboot) label="Redémarrer l'ordinateur" ;;
  suspend) label="Mettre en veille" ;;
  logout) label="Fermer la session Hyprland" ;;
  *) exit 2 ;;
esac
choice="$(printf 'Annuler\nConfirmer' | tofi --prompt-text "$label ?")" || exit 0
[[ "$choice" == "Confirmer" ]] || exit 0
case "$action" in
  poweroff) exec systemctl poweroff ;;
  reboot) exec systemctl reboot ;;
  suspend) exec systemctl suspend ;;
  logout) exec hyprctl dispatch exit ;;
esac
EOF
  write_user_file_if_missing "$bindir/hyprland-confirm-power" "$tmp" 700
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -u
CONFIG="$HOME/.config/wlogout/layout"
CSS="$HOME/.config/wlogout/style.css"
exec wlogout --layout "$CONFIG" --css "$CSS" --protocol layer-shell
EOF
  write_user_file_if_missing "$bindir/hyprland-power-menu" "$tmp" 700
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -u
if ! command -v kitty >/dev/null 2>&1 || ! command -v fastfetch >/dev/null 2>&1; then exit 0; fi
# Keep a visible terminal open after the one-shot Fastfetch report.
exec kitty --class hyprland-fastfetch --title 'SYSTEM // FASTFETCH' zsh -lc 'fastfetch; printf "\n\033[2mFerme cette fenêtre quand tu as fini.\033[0m\n\n"; exec zsh -i'
EOF
  write_user_file_if_missing "$bindir/hyprland-fastfetch-window" "$tmp" 700
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -u
selected="$(tofi-drun 2>/dev/null)" || exit 0
[[ -n "$selected" ]] || exit 0
exec hyprctl dispatch exec "$selected"
EOF
  write_user_file_if_missing "$bindir/hyprland-app-launcher" "$tmp" 700
  rm -f "$tmp"

  record "helper-scripts" "CREATED_IF_MISSING:$bindir" "$RUN_DIR/configured.tsv"
}

install_sddm_glass_theme() {
  local localtheme="$RUN_DIR/sddm-glass-theme"
  if ! pacman -Q sddm >/dev/null 2>&1 && (( ! DRY_RUN )); then
    warn "SDDM n'est pas installé; thème Glass non déployé."
    record "sddm-theme" "SDDM_NOT_INSTALLED" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  mkdir -p "$localtheme"
  cat > "$localtheme/metadata.desktop" <<'EOF'
[SddmGreeterTheme]
Name=Hyprland Glass Monochrome
Description=Minimal black, grey and white login theme with a cosmic background.
Author=Local user theme
Copyright=2026
License=MIT
Type=sddm-theme
Version=1.0
MainScript=Main.qml
ConfigFile=
TranslationsDirectory=translations
Theme-Id=hyprland-glass-mono
Theme-API=2.0
EOF
  cat > "$localtheme/Main.qml" <<'QML'
import QtQuick 2.0
import SddmComponents 2.0

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: "#080808"
    focus: true
    property int sessionIndex: session.index

    TextConstants { id: textConstants }

    Image {
        anchors.fill: parent
        source: "wallpaper.png"
        fillMode: Image.PreserveAspectCrop
        smooth: true
        asynchronous: false
    }
    Rectangle { anchors.fill: parent; color: "#b0080808" }

    Text {
        id: clock
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.19
        text: Qt.formatDateTime(new Date(), "hh:mm")
        color: "#f5f5f5"
        font.family: "FiraCode Nerd Font"
        font.pixelSize: 82
    }
    Text {
        id: dateLine
        anchors.horizontalCenter: parent.horizontalCenter
        y: clock.y + 96
        text: Qt.formatDateTime(new Date(), "dddd · dd MMMM yyyy")
        color: "#bdbdbd"
        font.family: "Noto Sans"
        font.pixelSize: 18
    }
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: { clock.text = Qt.formatDateTime(new Date(), "hh:mm"); dateLine.text = Qt.formatDateTime(new Date(), "dddd · dd MMMM yyyy"); }
    }

    Rectangle {
        id: panel
        width: 420; height: 350
        anchors.centerIn: parent
        radius: 18
        color: "#cc171717"
        border.width: 1
        border.color: "#888888"

        Column {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 13
            Text {
                text: "ENDEAVOUROS  /  HYPRLAND"
                color: "#f5f5f5"
                font.family: "FiraCode Nerd Font"
                font.pixelSize: 16
                anchors.horizontalCenter: parent.horizontalCenter
            }
            TextInput {
                id: userInput
                text: userModel.lastUser
                width: parent.width
                height: 42
                color: "#f5f5f5"
                selectionColor: "#777777"
                font.family: "Noto Sans"
                font.pixelSize: 16
                verticalAlignment: TextInput.AlignVCenter
                Rectangle { anchors.fill: parent; z: -1; radius: 7; color: "#332f2f2f"; border.width: 1; border.color: "#666666" }
                Keys.onReturnPressed: passwordInput.forceActiveFocus()
            }
            TextInput {
                id: passwordInput
                width: parent.width
                height: 42
                color: "#f5f5f5"
                selectionColor: "#777777"
                echoMode: TextInput.Password
                passwordCharacter: "●"
                font.family: "Noto Sans"
                font.pixelSize: 16
                verticalAlignment: TextInput.AlignVCenter
                focus: true
                Rectangle { anchors.fill: parent; z: -1; radius: 7; color: "#332f2f2f"; border.width: 1; border.color: "#666666" }
                Keys.onReturnPressed: sddm.login(userInput.text, passwordInput.text, session.index)
            }
            ComboBox {
                id: session
                width: parent.width
                model: sessionModel
                index: sessionModel.lastIndex
                font.pixelSize: 14
            }
            Rectangle {
                width: parent.width; height: 44; radius: 8
                color: loginMouse.containsMouse ? "#f5f5f5" : "#d9d9d9"
                Text { anchors.centerIn: parent; text: "SE CONNECTER"; color: "#111111"; font.family: "FiraCode Nerd Font"; font.pixelSize: 14 }
                MouseArea { id: loginMouse; anchors.fill: parent; hoverEnabled: true; onClicked: sddm.login(userInput.text, passwordInput.text, session.index) }
            }
            Text {
                id: errorLabel
                width: parent.width
                text: ""
                color: "#eeeeee"
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 12
            }
        }
    }

    Connections {
        target: sddm
        function onLoginFailed() { errorLabel.text = textConstants.loginFailed; passwordInput.text = ""; passwordInput.forceActiveFocus(); }
        function onInformationMessage(message) { errorLabel.text = message; }
    }
}
QML

  if (( DRY_RUN )); then
    say "--dry-run: thème SDDM Glass créé seulement dans le dossier de rapport, pas installé."
    return 0
  fi

  local wallpaper="$HOME/Pictures/Wallpapers/glass-cosmos.png"
  if [[ ! -s "$wallpaper" ]]; then
    warn "Fond cosmique manquant; le thème SDDM ne sera pas activé automatiquement."
    record "sddm-theme" "NO_WALLPAPER" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  local target="/usr/share/sddm/themes/hyprland-glass-mono"
  sudo mkdir -p "$target"
  # Back up only files being replaced in the theme directory.
  for f in metadata.desktop Main.qml wallpaper.png; do
    backup_system_file "$target/$f" || true
  done
  sudo install -m 644 "$localtheme/metadata.desktop" "$target/metadata.desktop"
  sudo install -m 644 "$localtheme/Main.qml" "$target/Main.qml"
  sudo install -m 644 "$wallpaper" "$target/wallpaper.png"

  # Activate theme only if SDDM is the current manager or none is selected.
  local current_dm=""
  if [[ -L /etc/systemd/system/display-manager.service ]]; then
    current_dm="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)" 2>/dev/null || true)"
  fi
  if [[ -z "$current_dm" || "$current_dm" == "sddm.service" || "$current_dm" == "sddm" ]]; then
    local conf="/etc/sddm.conf.d/99-hyprland-glass-mono.conf"
    backup_system_file "$conf" || true
    local ctmp; ctmp="$(mktemp)"
    cat > "$ctmp" <<'EOF'
[Theme]
Current=hyprland-glass-mono
EOF
    sudo install -D -m 644 "$ctmp" "$conf"
    rm -f "$ctmp"
    ok "Thème SDDM Glass installé et sélectionné. Pour revenir au thème précédent: supprimer /etc/sddm.conf.d/99-hyprland-glass-mono.conf puis redémarrer SDDM."
    record "sddm-theme" "INSTALLED_AND_SELECTED" "$RUN_DIR/configured.tsv"
  else
    warn "Thème SDDM installé, mais non sélectionné car un autre display manager est déjà configuré ($current_dm)."
    record "sddm-theme" "INSTALLED_NOT_SELECTED:$current_dm" "$RUN_DIR/skipped.tsv"
  fi
}

write_configs() {
  if (( SKIP_CONFIG || DRY_RUN )); then
    say "Configuration utilisateur ignorée (--skip-config ou --dry-run)."
    return 0
  fi

  say "Préparation des dossiers, du fond cosmique et des scripts locaux."
  mkdir -p "$HOME/Pictures/Screenshots" "$HOME/Videos/Recordings" "$HOME/Pictures/Wallpapers" \
    "$HOME/.config/hypr" "$HOME/.config/waybar" "$HOME/.config/kitty" "$HOME/.config/tofi" \
    "$HOME/.config/mako" "$HOME/.config/hyprlock" "$HOME/.config/hypridle" "$HOME/.config/wlogout" \
    "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0" "$HOME/.config/Kvantum" "$HOME/.config/qt6ct"
  local wallpaper
  generate_wallpaper >/dev/null
  wallpaper="$HOME/Pictures/Wallpapers/glass-cosmos.png"
  write_helper_scripts

  local body tmp
  # Hyprland config block is separate and idempotent. It is sourced from the existing main config.
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# AZERTY FR, monochrome Glass. Ordinary windows are floating by preference.
\$componentsMod = SUPER
monitor = , preferred, auto, 1
input {
    kb_layout = fr
    follow_mouse = 1
    sensitivity = 0
}
general {
    gaps_in = 6
    gaps_out = 12
    border_size = 2
    col.active_border = rgba(eeeeeeff)
    col.inactive_border = rgba(626262cc)
    resize_on_border = true
    layout = dwindle
}
dwindle {
    pseudotile = true
    preserve_split = true
}
decoration {
    rounding = 12
    active_opacity = 0.94
    inactive_opacity = 0.88
    fullscreen_opacity = 1.0
    shadow {
        enabled = true
        range = 8
        render_power = 3
        color = rgba(00000066)
    }
    blur {
        enabled = true
        size = 6
        passes = 2
        new_optimizations = true
        xray = false
    }
}
animations {
    enabled = true
    bezier = glassEase, 0.22, 1, 0.36, 1
    animation = windows, 1, 5, glassEase, popin 80%
    animation = windowsOut, 1, 4, glassEase, popin 80%
    animation = border, 1, 4, default
    animation = fade, 1, 4, default
    animation = workspaces, 1, 4, glassEase, slide
}
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
# Prefer floating/manual placement for ordinary applications.
windowrule = match:class .*, float
windowrule = match:class ^(pavucontrol|blueman-manager|nm-connection-editor|qt5ct|qt6ct|nwg-look|swappy|wlogout)$, center
# Apps and utilities
bind = \$componentsMod, RETURN, exec, kitty
bind = \$componentsMod, E, exec, dolphin
bind = \$componentsMod, SPACE, exec, $HOME/.local/bin/hyprland-app-launcher
bind = \$componentsMod, BACKSPACE, killactive
bind = \$componentsMod, F, togglefloating
bind = \$componentsMod, L, exec, $HOME/.local/bin/hyprland-lock
bind = \$componentsMod SHIFT, ESCAPE, exec, $HOME/.local/bin/hyprland-power-menu
# Mouse: hold SUPER and drag to move/resize floating windows.
bindm = \$componentsMod, mouse:272, movewindow
bindm = \$componentsMod, mouse:273, resizewindow
# Workspaces 1-5 use physical number-row keycodes (AZERTY-safe).
bind = \$componentsMod, code:10, workspace, 1
bind = \$componentsMod, code:11, workspace, 2
bind = \$componentsMod, code:12, workspace, 3
bind = \$componentsMod, code:13, workspace, 4
bind = \$componentsMod, code:14, workspace, 5
bind = \$componentsMod SHIFT, code:10, movetoworkspace, 1
bind = \$componentsMod SHIFT, code:11, movetoworkspace, 2
bind = \$componentsMod SHIFT, code:12, movetoworkspace, 3
bind = \$componentsMod SHIFT, code:13, movetoworkspace, 4
bind = \$componentsMod SHIFT, code:14, movetoworkspace, 5
# Screenshot and recording helpers.
bind = \$componentsMod SHIFT, S, exec, $HOME/.local/bin/hyprland-screenshot
bind = \$componentsMod, PRINT, exec, $HOME/.local/bin/hyprland-screenshot-full
bind = \$componentsMod SHIFT, R, exec, $HOME/.local/bin/hyprland-record
# Volume / brightness with SwayOSD.
bindel = , XF86AudioRaiseVolume, exec, swayosd-client --output-volume raise
bindel = , XF86AudioLowerVolume, exec, swayosd-client --output-volume lower
bindl = , XF86AudioMute, exec, swayosd-client --output-volume mute-toggle
bindel = , XF86MonBrightnessUp, exec, swayosd-client --brightness raise
bindel = , XF86MonBrightnessDown, exec, swayosd-client --brightness lower
# Session environment and auto-start. Portals are D-Bus/systemd activated, not exec-once.
env = XCURSOR_THEME,Bibata-Modern-Ice
env = XCURSOR_SIZE,24
env = GTK_THEME,Adwaita:dark
env = QT_STYLE_OVERRIDE,kvantum
exec-once = waybar
exec-once = mako
exec-once = hyprpaper
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = nm-applet --indicator
exec-once = hypridle
exec-once = wl-paste --type text --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store
exec-once = swayosd-server
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=Hyprland XDG_SESSION_TYPE=wayland
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
exec-once = $HOME/.local/bin/hyprland-fastfetch-window
EOF
  write_user_block "$HOME/.config/hypr/hyprland-components.conf" "hyprland-main" "$tmp"
  rm -f "$tmp"

  # Safely add the include to the primary config only once, preserving user lines.
  local main="$HOME/.config/hypr/hyprland.conf"
  tmp="$(mktemp)"
  printf 'source = ~/.config/hypr/hyprland-components.conf\n' > "$tmp"
  if [[ -f "$main" ]] && grep -Eq '^[[:space:]]*source[[:space:]]*=[[:space:]]*~/.config/hypr/hyprland-components[.]conf([[:space:]]*(#.*)?)?$' "$main"; then
    ok "La source Hyprland est déjà présente dans $main"
  else
    write_user_block "$main" "components-include" "$tmp"
  fi
  rm -f "$tmp"

  # Kitty Glass monochrome block.
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
font_family FiraCode Nerd Font
font_size 11.0
shell /usr/bin/zsh
foreground #f2f2f2
background #0b0b0b
selection_foreground #111111
selection_background #e5e5e5
cursor #f2f2f2
cursor_text_color #111111
background_opacity 0.88
dynamic_background_opacity yes
window_padding_width 10
hide_window_decorations titlebar-only
enable_audio_bell no
confirm_os_window_close 0
EOF
  write_user_block "$HOME/.config/kitty/kitty.conf" "kitty-glass" "$tmp"
  rm -f "$tmp"

  # Tofi: its own renderer may not support all GTK-like rounded corners; alpha and border are used.
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
font = "FiraCode Nerd Font"
font-size = 12
prompt-text = "Search"
width = 42%
height = 42%
anchor = center
background-color = #151515ee
text-color = #f2f2f2
selection-color = #111111
selection-background = #eeeeee
border-width = 1
border-color = #777777
outline-width = 0
padding-left = 18
padding-right = 18
padding-top = 12
padding-bottom = 12
EOF
  write_user_block "$HOME/.config/tofi/config" "tofi-glass" "$tmp"
  rm -f "$tmp"

  # Waybar Cyber Workstation (top; left workspaces/window, center system, right net/audio/clock/tray).
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 36,
  "spacing": 4,
  "modules-left": ["hyprland/workspaces", "hyprland/window"],
  "modules-center": ["cpu", "memory", "temperature"],
  "modules-right": ["network", "pulseaudio", "clock", "tray"],
  "hyprland/workspaces": {
    "disable-scroll": true,
    "all-outputs": true,
    "format": "{name}",
    "persistent-workspaces": {"*": 5}
  },
  "hyprland/window": {"max-length": 48, "separate-outputs": true, "format": "{title}"},
  "cpu": {"interval": 3, "format": "CPU {usage}%", "tooltip": true},
  "memory": {"interval": 5, "format": "RAM {percentage}%", "tooltip": true},
  "temperature": {"interval": 5, "format": "TEMP {temperatureC}°C", "format-critical": "TEMP {temperatureC}°C", "critical-threshold": 85, "tooltip": true},
  "network": {"interval": 5, "format-wifi": "WIFI {essid}", "format-ethernet": "LAN {ifname}", "format-disconnected": "NET offline", "tooltip-format": "{ifname}\n{ipaddr}/{cidr}", "max-length": 28},
  "pulseaudio": {"format": "VOL {volume}%", "format-muted": "VOL muted", "scroll-step": 5, "on-click": "pavucontrol", "tooltip": true},
  "clock": {"interval": 60, "format": "{:%a %d %b  %H:%M}", "tooltip-format": "{:%A %d %B %Y}"},
  "tray": {"icon-size": 16, "spacing": 8}
}
EOF
  write_user_block_jsonc "$HOME/.config/waybar/config.jsonc" "waybar-config" "$tmp"
  rm -f "$tmp"
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
* { border: none; border-radius: 0; font-family: "FiraCode Nerd Font", "Noto Sans"; font-size: 11px; min-height: 0; }
window#waybar { background: transparent; color: #f2f2f2; }
#workspaces, #window, #cpu, #memory, #temperature, #network, #pulseaudio, #clock, #tray {
  background: rgba(22, 22, 22, 0.88);
  color: #eeeeee;
  border: 1px solid rgba(145,145,145,0.55);
  border-radius: 10px;
  margin: 4px 4px;
  padding: 2px 10px;
}
#workspaces button { color: #bcbcbc; padding: 0 7px; background: transparent; border-radius: 7px; }
#workspaces button.active { color: #111111; background: #f0f0f0; }
#workspaces button:hover { color: #ffffff; background: #444444; box-shadow: none; }
#window { color: #bdbdbd; }
#cpu, #memory, #temperature { color: #f2f2f2; }
#network.disconnected { color: #999999; }
#pulseaudio.muted { color: #999999; }
#clock { color: #ffffff; font-weight: 600; }
EOF
  write_user_block_css "$HOME/.config/waybar/style.css" "waybar-glass" "$tmp"
  rm -f "$tmp"

  # Mako compact, top-right notifications.
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
font=FiraCode Nerd Font 10
background-color=#171717ee
text-color=#f2f2f2
border-color=#777777
border-size=1
border-radius=10
padding=12
margin=10
width=360
height=120
default-timeout=5000
ignore-timeout=0
max-visible=4
anchor=top-right
layer=overlay
EOF
  write_user_block "$HOME/.config/mako/config" "mako-glass" "$tmp"
  rm -f "$tmp"

  # Hyprpaper classic config syntax; if installed version rejects it, package is skipped in report and user can adjust.
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
preload = $wallpaper
wallpaper = ,$wallpaper
splash = false
EOF
  write_user_block "$HOME/.config/hypr/hyprpaper.conf" "hyprpaper-cosmos" "$tmp"
  rm -f "$tmp"

  # Hyprlock: minimalist centered clock/date/password. This is not a real user password stored on disk.
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
background {
    monitor =
    path = $wallpaper
    blur_passes = 2
    blur_size = 4
    color = rgba(080808dd)
}
label {
    monitor =
    text = cmd[update:1000] date +"%H:%M"
    color = rgba(f5f5f5ff)
    font_size = 92
    font_family = FiraCode Nerd Font
    position = 0, 150
    halign = center
    valign = center
}
label {
    monitor =
    text = cmd[update:60000] date +"%A · %d %B"
    color = rgba(bdbdbdff)
    font_size = 20
    font_family = Noto Sans
    position = 0, 70
    halign = center
    valign = center
}
input-field {
    monitor =
    size = 330, 58
    outline_thickness = 2
    dots_size = 0.25
    dots_spacing = 0.18
    dots_center = true
    outer_color = rgba(eeeeeeff)
    inner_color = rgba(222222cc)
    font_color = rgba(f5f5f5ff)
    fade_on_empty = false
    placeholder_text = <span foreground="##bdbdbd">Mot de passe</span>
    check_color = rgba(eeeeeeaa)
    fail_color = rgba(aaaaaaaa)
    fail_text = <span foreground="##ffffff">Erreur — réessayer</span>
    position = 0, -80
    halign = center
    valign = center
}
EOF
  write_user_block "$HOME/.config/hypr/hyprlock.conf" "hyprlock-glass" "$tmp"
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
general {
    lock_cmd = $HOME/.local/bin/hyprland-lock
    before_sleep_cmd = $HOME/.local/bin/hyprland-lock
    after_sleep_cmd = hyprctl dispatch dpms on
}
listener {
    timeout = 300
    on-timeout = $HOME/.local/bin/hyprland-lock
}
listener {
    timeout = 600
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
EOF
  write_user_block "$HOME/.config/hypr/hypridle.conf" "hypridle-timers" "$tmp"
  rm -f "$tmp"

  # Wlogout custom layout and monochrome stylesheet.
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[
  {"label":"lock","action":"$HOME/.local/bin/hyprland-lock","text":"Verrouiller","keybind":"l"},
  {"label":"suspend","action":"$HOME/.local/bin/hyprland-confirm-power suspend","text":"Veille","keybind":"s"},
  {"label":"logout","action":"$HOME/.local/bin/hyprland-confirm-power logout","text":"Déconnexion","keybind":"e"},
  {"label":"reboot","action":"$HOME/.local/bin/hyprland-confirm-power reboot","text":"Redémarrer","keybind":"r"},
  {"label":"shutdown","action":"$HOME/.local/bin/hyprland-confirm-power poweroff","text":"Éteindre","keybind":"p"}
]
EOF
  replace_user_file "$HOME/.config/wlogout/layout" "$tmp"
  rm -f "$tmp"
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
* { background-image: none; font-family: "FiraCode Nerd Font", "Noto Sans"; }
window { background-color: rgba(0,0,0,0.55); }
button { color: #f2f2f2; background-color: rgba(24,24,24,0.94); border: 1px solid rgba(150,150,150,0.6); border-radius: 14px; margin: 8px; padding: 22px; }
button:hover, button:focus { color: #111111; background-color: #eeeeee; border-color: #ffffff; }
label { font-size: 14px; }
EOF
  write_user_block_css "$HOME/.config/wlogout/style.css" "wlogout-style" "$tmp"
  rm -f "$tmp"

  # GTK dark preference; merge only managed keys through small settings blocks in the INI files.
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
gtk-font-name=Noto Sans 10
gtk-cursor-theme-name=Bibata-Modern-Ice
gtk-cursor-theme-size=24
EOF
  write_user_block "$HOME/.config/gtk-3.0/settings.ini" "gtk3-dark-settings" "$tmp"
  write_user_block "$HOME/.config/gtk-4.0/settings.ini" "gtk4-dark-settings" "$tmp"
  rm -f "$tmp"

  # Vim development defaults, managed block only.
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
set nocompatible
syntax on
filetype plugin indent on
set number
set relativenumber
set ruler
set showcmd
set wildmenu
set incsearch
set hlsearch
set ignorecase
set smartcase
set expandtab
set tabstop=4
set shiftwidth=4
set softtabstop=4
set autoindent
set smartindent
set nowrap
set termguicolors
set background=dark
highlight Normal ctermbg=NONE guibg=#0b0b0b guifg=#f2f2f2
highlight LineNr guifg=#777777
highlight CursorLineNr guifg=#ffffff gui=bold
augroup HyprlandComponentsFiletypes
  autocmd!
  autocmd FileType javascript,typescript,json,html,css setlocal tabstop=2 shiftwidth=2 softtabstop=2
  autocmd FileType sh,bash,conf,python setlocal expandtab
augroup END
EOF
  write_user_block_vim "$HOME/.vimrc" "vim-dev" "$tmp"
  rm -f "$tmp"

  # Starship prompt: monochrome and compact; managed block preserves unrelated settings.
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
add_newline = false
format = "$directory$git_branch$git_status$character"
[directory]
style = "bold white"
truncation_length = 3
truncate_to_repo = true
[git_branch]
style = "bright-white"
format = " [$branch]($style)"
[git_status]
style = "dimmed white"
[character]
success_symbol = "[❯](bold white)"
error_symbol = "[❯](bold bright-black)"
EOF
  write_user_block "$HOME/.config/starship.toml" "starship-monochrome" "$tmp"
  rm -f "$tmp"

  # Zsh block: keep existing .zshrc content, append only a managed section.
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# Basic history and completion
HISTSIZE=10000
SAVEHIST=10000
HISTFILE="$HOME/.zsh_history"
setopt HIST_IGNORE_DUPS SHARE_HISTORY AUTO_CD INTERACTIVE_COMMENTS
mkdir -p "$HOME/.cache/zsh"
[[ -d /usr/share/zsh/site-functions ]] && fpath=(/usr/share/zsh/site-functions $fpath)
autoload -Uz compinit && compinit -d "$HOME/.cache/zsh/zcompdump-$ZSH_VERSION"
# Starship prompt
if command -v starship >/dev/null 2>&1; then eval "$(starship init zsh)"; fi
# Fast, useful terminal navigation
if command -v zoxide >/dev/null 2>&1; then eval "$(zoxide init zsh)"; fi
command -v eza >/dev/null 2>&1 && alias ls='eza --group-directories-first' && alias ll='eza -lah --group-directories-first'
command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never'
if command -v fzf >/dev/null 2>&1; then
  [[ -f /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh
  [[ -f /usr/share/fzf/completion.zsh ]] && source /usr/share/fzf/completion.zsh
fi
# Optional plugins: source only when their files exist.
[[ -r /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -r /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF
  write_user_block "$HOME/.zshrc" "zsh-modern" "$tmp"
  rm -f "$tmp"

  # Fastfetch once-per-graphical-login happens through the dedicated Kitty exec-once, not .zshrc.

  # Apply GTK and icon-theme cursor preference via environment; do not set an icon theme (user chose defaults).
  if [[ -d "$HOME/.config/Kvantum" ]] && [[ -d /usr/share/Kvantum ]]; then
    local kv_theme=""
    for candidate in KvArcDark KvGnomeDark KvAdaptaDark KvMojaveDark; do
      if [[ -d "/usr/share/Kvantum/$candidate" ]]; then kv_theme="$candidate"; break; fi
    done
    if [[ -n "$kv_theme" ]]; then
      tmp="$(mktemp)"
      printf 'theme=%s\n' "$kv_theme" > "$tmp"
      write_user_block "$HOME/.config/Kvantum/kvantum.kvconfig" "kvantum-monochrome" "$tmp"
      rm -f "$tmp"
    else
      warn "Aucun thème Kvantum sombre connu n'a été détecté; Kvantum reste personnalisable via kvantummanager."
    fi
  fi

  # Create the custom SDDM theme and activate only in non-dry-run mode.
  install_sddm_glass_theme

  # Switch the default shell only if Zsh exists and it is not already the login shell.
  if command -v zsh >/dev/null 2>&1; then
    local zshpath; zshpath="$(command -v zsh)"
    if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$zshpath" ]]; then
      if ask_yes_no "Définir Zsh comme shell de connexion pour $USER ?" yes; then
        if grep -Fxq "$zshpath" /etc/shells; then
          chsh -s "$zshpath" "$USER" && ok "Shell de connexion défini sur Zsh (effet à la prochaine connexion)." || record "chsh" "FAILED" "$RUN_DIR/failed.tsv"
        else
          warn "$zshpath n'est pas listé dans /etc/shells; chsh ignoré."
          record "chsh" "ZSH_NOT_LISTED_IN_SHELLS" "$RUN_DIR/skipped.tsv"
        fi
      fi
    else
      ok "Zsh est déjà le shell de connexion."
    fi
  fi

  # Set system keyboard maps with backups. localectl is systemd's official configuration interface.
  if command -v localectl >/dev/null 2>&1; then
    backup_system_file /etc/vconsole.conf || true
    backup_system_file /etc/X11/xorg.conf.d/00-keyboard.conf || true
    if ask_yes_no "Appliquer AZERTY français au TTY et à XKB/SDDM via localectl ?" yes; then
      sudo localectl set-keymap fr-latin9 || warn "localectl set-keymap fr-latin9 a échoué; vérifie la liste des keymaps disponibles."
      sudo localectl set-x11-keymap fr pc105 || warn "localectl set-x11-keymap fr pc105 a échoué; configuration à vérifier manuellement."
    fi
  fi

  record "User configuration" "MANAGED_BLOCKS_WRITTEN" "$RUN_DIR/configured.tsv"
}

configure_file_associations() {
  if (( SKIP_CONFIG || DRY_RUN )); then return 0; fi
  if ! command -v xdg-mime >/dev/null 2>&1; then
    warn "xdg-mime introuvable; associations de fichiers non modifiées."
    record "mime-associations" "XDG_MIME_NOT_FOUND" "$RUN_DIR/skipped.tsv"
    return 1
  fi
  local mime desktop
  backup_user_file "$HOME/.config/mimeapps.list" || {
    warn "Impossible de sauvegarder mimeapps.list; associations non modifiées."
    record "mime-associations" "BACKUP_FAILED" "$RUN_DIR/skipped.tsv"
    return 1
  }
  local pairs=(
    "inode/directory org.kde.dolphin.desktop"
    "image/png org.kde.gwenview.desktop"
    "image/jpeg org.kde.gwenview.desktop"
    "image/gif org.kde.gwenview.desktop"
    "image/webp org.kde.gwenview.desktop"
    "image/svg+xml org.kde.gwenview.desktop"
    "application/pdf org.kde.okular.desktop"
    "video/mp4 vlc.desktop"
    "video/x-matroska vlc.desktop"
    "video/webm vlc.desktop"
    "video/mpeg vlc.desktop"
  )
  for pair in "${pairs[@]}"; do
    mime="${pair%% *}"
    desktop="${pair#* }"
    if [[ -f "/usr/share/applications/$desktop" ]]; then
      if xdg-mime default "$desktop" "$mime"; then
        record "$mime" "$desktop" "$RUN_DIR/configured.tsv"
      else
        warn "Association non appliquée: $mime -> $desktop"
        record "$mime" "FAILED:$desktop" "$RUN_DIR/failed.tsv"
      fi
    else
      warn "Fichier desktop absent ($desktop); association $mime laissée inchangée."
      record "$mime" "DESKTOP_FILE_MISSING:$desktop" "$RUN_DIR/skipped.tsv"
    fi
  done
  ok "Associations MIME configurées avec sauvegarde préalable. Vim reste l'éditeur terminal."
}

write_report() {
  {
    echo "Hyprland Components Installer $VERSION"
    echo "Date: $(date -Is)"
    echo "User: $USER"
    echo "Run directory: $RUN_DIR"
    echo "Backup directory: $BACKUP_DIR"
    echo
    echo "=== Installed / already present ==="
    cat "$RUN_DIR/installed.tsv" 2>/dev/null || true
    echo
    echo "=== Configurations ==="
    cat "$RUN_DIR/configured.tsv" 2>/dev/null || true
    echo
    echo "=== Skipped / blocked ==="
    cat "$RUN_DIR/skipped.tsv" 2>/dev/null || true
    echo
    echo "=== Failed / cancelled ==="
    cat "$RUN_DIR/failed.tsv" 2>/dev/null || true
    echo
    echo "=== Backup manifest ==="
    cat "$MANIFEST_FILE" 2>/dev/null || true
    echo
    echo "=== Important notes ==="
    cat "$RUN_DIR/notes.txt" 2>/dev/null || true
  } > "$REPORT_FILE"
  chmod 600 "$REPORT_FILE"
}

write_restore_instructions() {
  cat > "$BACKUP_DIR/RESTORE.txt" <<EOF
Sauvegardes: $BACKUP_DIR
Manifeste: $MANIFEST_FILE

La configuration a été modifiée uniquement par blocs marqués MANAGED BY HYPRLAND COMPONENTS.
Pour revenir à la version précédente d'un fichier EXISTING, recopier la sauvegarde correspondante
au chemin source indiqué dans le manifeste. Pour un fichier marqué NEW, supprimer le fichier ou
retirer uniquement le bloc géré correspondant (ne supprime pas un fichier qui contenait du contenu
personnel antérieur). Les fichiers système doivent être restaurés avec sudo.

Restauration des fichiers utilisateur (à examiner avant usage, ne pas exécuter à l'aveugle):
  Les sauvegardes sous files/home/ conservent le chemin relatif à ton dossier personnel
  (par exemple files/home/.config/hypr/hyprland.conf). Consulte le manifeste, puis recopie
  uniquement les fichiers EXISTING vers leurs chemins d'origine. Pour les fichiers NEW,
  supprime-les uniquement si tu souhaites retirer le composant ajouté.

Les services activés peuvent être désactivés séparément, après examen du rapport:
  sudo systemctl disable --now firewalld.service
  sudo systemctl disable --now bluetooth.service
  sudo systemctl disable --now power-profiles-daemon.service
  sudo systemctl disable --now NetworkManager.service
  sudo systemctl disable sddm.service
N'exécute pas ces commandes en bloc sans vérifier quels services étaient déjà actifs avant l'installation.

Restauration de l'écran SDDM Glass en désactivant uniquement son drop-in:
  sudo rm -f /etc/sddm.conf.d/99-hyprland-glass-mono.conf
  sudo systemctl restart sddm.service

Journal: $LOG_FILE
Rapport: $REPORT_FILE
EOF
}

# Main run
say "Hyprland Components Installer $VERSION"
echo "Ce script ajoute les composants autour d'Hyprland déjà installé; il n'installe pas Hyprland."
echo "Aucune mise à niveau globale (-Syu), aucune transaction forcée et aucune modification volontaire des paquets verrouillés."
echo "Run: $RUN_DIR"
echo ""

say "Audit de la pile Hyprland verrouillée (contrôle seulement)."
for p in "${PROTECTED_PACKAGES[@]}"; do
  if q="$(pacman -Q "$p" 2>/dev/null)"; then
    actual="${q#* }"
    expected="${EXPECTED_VERSIONS[$p]:-verrouillé, version attendue inconnue}"
    if [[ "$expected" != "verrouillé, version attendue inconnue" && "$actual" != "$expected" ]]; then
      warn "$p installé en $actual; version historique notée par toi: $expected. Aucun changement ne sera tenté sur ce paquet."
      record "$p" "VERSION_DIFFERS:installed=$actual:expected=$expected" "$RUN_DIR/notes.txt"
    else
      ok "$p: $actual"
    fi
  else
    warn "$p non installé localement; le script ne l'installera pas."
    record "$p" "NOT_INSTALLED_NOT_TOUCHED" "$RUN_DIR/notes.txt"
  fi
done

if (( DRY_RUN )); then
  say "Mode aperçu activé. Aucun fichier de configuration ou service ne sera modifié."
else
  echo ""
  cat <<'EOF'
Composants sélectionnés dans ce script:
  - Bureau: Dolphin, Kitty, Vim, Waybar, Tofi, Mako, Hyprpaper, Hyprlock, Hypridle, Wlogout
  - Captures/vidéos: Grim, Slurp, Swappy, wf-recorder; audio vidéo choisi à chaque lancement
  - Audio: PipeWire, WirePlumber, pipewire-pulse, Pavucontrol
  - Session: SDDM + thème Glass, Polkit-GNOME, portails Wayland, XWayland
  - Réseau: NetworkManager, nm-applet, nmtui, BlueZ/Blueman, outils réseau de diagnostic, Firewalld
  - Développement: Git, base-devel, Python, Node.js/npm, Go, Rust/Cargo
  - Terminal: Zsh + Starship + extensions, fzf, zoxide, eza, bat, btop, tmux, fastfetch
  - Style: Kvantum/GTK sombre, FiraCode Nerd Font, Noto, Bibata Modern Ice (AUR)
EOF
  if (( ! YES )) && ! ask_yes_no "Continuer avec l'installation par groupes (chaque transaction Pacman reste confirmée manuellement) ?" no; then
    warn "Installation annulée par l'utilisateur."
    record "main" "USER_CANCELLED" "$RUN_DIR/skipped.tsv"
    write_report
    write_restore_instructions
    echo "Rapport: $REPORT_FILE"
    exit 0
  fi
  sudo -v || { err "sudo non disponible."; exit 1; }
fi

# Official repository package groups. Each group is previewed independently so an
# incompatible optional component doesn't block every unrelated component.
install_group "base-developpement" base-devel git curl wget python nodejs npm go rust cargo
install_group "terminal-shell" zsh starship fzf zoxide eza bat btop tmux vim fastfetch man-db man-pages
install_group "bureau-principal" kitty dolphin waybar tofi mako wlogout xorg-xwayland
install_group "captures-et-enregistrement" grim slurp swappy wl-clipboard cliphist wf-recorder
install_group "audio-pipewire" pipewire wireplumber pipewire-pulse pavucontrol
install_group "polkit" polkit-gnome
install_group "portail-principal" xdg-desktop-portal
install_group "portail-gtk" xdg-desktop-portal-gtk
install_group "portail-hyprland" xdg-desktop-portal-hyprland
install_group "hyprpaper" hyprpaper
install_group "hyprlock" hyprlock
install_group "hypridle" hypridle
install_group "gestionnaire-de-connexion" sddm
install_group "reseau-desktop" networkmanager network-manager-applet
install_group "terminal-reseau" bind whois traceroute mtr openssh tcpdump nmap
install_group "wireshark" wireshark-qt
install_group "bluetooth" bluez bluez-utils blueman
install_group "energie" brightnessctl power-profiles-daemon
install_group "pare-feu" firewalld
install_group "dolphin-archives" ark 7zip unzip zip kio-extras dolphin-plugins
install_group "dolphin-miniatures" ffmpegthumbs kdegraphics-thumbnailers
install_group "multimedia" gwenview okular vlc
install_group "themes-qt-gtk" nwg-look qt5ct qt6ct kvantum gsettings-desktop-schemas
install_group "polices" ttf-firacode-nerd noto-fonts noto-fonts-emoji
install_group "affichage-osd" swayosd
install_group "notifications-systeme" libnotify
install_group "mode-nuit" wlsunset
install_group "disque-usb" udisks2
install_group "associations-fichiers" xdg-utils
install_group "outils-shell-extensions" zsh-autosuggestions zsh-syntax-highlighting zsh-completions

# Cursor theme is intentionally AUR-only on many Arch systems; preview and ask before yay builds it.
install_yay_if_missing
install_aur_component_safely "bibata-cursor-theme" "Bibata Modern Ice"

if (( ! SKIP_CONFIG )); then
  write_configs
  configure_file_associations
else
  say "--skip-config: aucun fichier utilisateur ne sera écrit."
fi

if (( ! DRY_RUN )); then
  say "Activation prudente des services sélectionnés."
  # Avoid enabling services in dry-run. If packages weren't installed, the systemctl call simply fails and is logged.
  if pacman -Q networkmanager >/dev/null 2>&1; then start_networkmanager_safely; fi
  if pacman -Q bluez >/dev/null 2>&1; then enable_bluetooth_safely; fi
  if pacman -Q firewalld >/dev/null 2>&1; then enable_firewalld_safely; fi
  if pacman -Q power-profiles-daemon >/dev/null 2>&1; then enable_power_profiles_safely; fi
  if pacman -Q sddm >/dev/null 2>&1; then enable_sddm_safely; fi
  if [[ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null \
      && ok "Sockets et WirePlumber activés pour l'utilisateur." \
      || warn "Impossible d'activer PipeWire dans la session utilisateur courante; les unités seront vérifiées à la prochaine connexion."
  else
    say "Pas de bus utilisateur accessible; les services audio seront démarrés à la prochaine session graphique."
  fi
fi

write_restore_instructions
write_report
say "Terminé. Résumé:"
echo "  Journal  : $LOG_FILE"
echo "  Rapport  : $REPORT_FILE"
echo "  Manifeste: $MANIFEST_FILE"
echo "  Sauvegardes: $BACKUP_DIR"
echo ""
echo "Vérifie le rapport avant de redémarrer. Le script n'a pas lancé de mise à niveau globale."
echo "Si Hyprland affiche une erreur, passe sur un TTY (Ctrl+Alt+F3) et restaure les fichiers depuis le manifeste."
