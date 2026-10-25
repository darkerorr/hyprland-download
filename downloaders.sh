#!/usr/bin/env bash
# Restore and pin the Arch/EndeavourOS Hyprland 0.54.3-era package stack.
# This intentionally does NOT install a visual rice (Waybar/Rofi themes, shell, etc.).
set -Eeuo pipefail

readonly ARCHIVE='https://archive.archlinux.org/packages'

if [[ "$(uname -m)" != 'x86_64' ]]; then
  echo 'ERREUR : ce script cible les paquets Arch x86_64.' >&2
  exit 1
fi
if [[ "${EUID}" -eq 0 ]]; then
  echo 'Lance le script comme utilisateur normal, sans sudo devant le script.' >&2
  echo 'Il appellera sudo lorsque nécessaire.' >&2
  exit 1
fi
if ! command -v pacman >/dev/null || ! command -v sudo >/dev/null; then
  echo 'ERREUR : pacman et sudo sont requis.' >&2
  exit 1
fi

# Format : paquet|version|URL Arch Linux Archive
# Les versions du cœur ont été utilisées ensemble avec Hyprland 0.54.3-2.
# Les utilitaires Hypr sont des builds de la période où hyprutils 0.12.0 était utilisé.
PACKAGE_SPECS=$(cat <<EOF_SPECS
hyprland|0.54.3-2|$ARCHIVE/h/hyprland/hyprland-0.54.3-2-x86_64.pkg.tar.zst
aquamarine|0.10.0-4|$ARCHIVE/a/aquamarine/aquamarine-0.10.0-4-x86_64.pkg.tar.zst
hyprutils|0.12.0-1|$ARCHIVE/h/hyprutils/hyprutils-0.12.0-1-x86_64.pkg.tar.zst
hyprgraphics|0.5.1-1|$ARCHIVE/h/hyprgraphics/hyprgraphics-0.5.1-1-x86_64.pkg.tar.zst
hyprcursor|0.1.13-5|$ARCHIVE/h/hyprcursor/hyprcursor-0.1.13-5-x86_64.pkg.tar.zst
hyprlang|0.6.8-3|$ARCHIVE/h/hyprlang/hyprlang-0.6.8-3-x86_64.pkg.tar.zst
hyprtoolkit|0.5.3-2|$ARCHIVE/h/hyprtoolkit/hyprtoolkit-0.5.3-2-x86_64.pkg.tar.zst
hyprwire|0.3.0-2|$ARCHIVE/h/hyprwire/hyprwire-0.3.0-2-x86_64.pkg.tar.zst
hyprland-guiutils|0.2.1-3|$ARCHIVE/h/hyprland-guiutils/hyprland-guiutils-0.2.1-3-x86_64.pkg.tar.zst
hyprwayland-scanner|0.4.5-1|$ARCHIVE/h/hyprwayland-scanner/hyprwayland-scanner-0.4.5-1-x86_64.pkg.tar.zst
libjxl|0.11.2-2|$ARCHIVE/l/libjxl/libjxl-0.11.2-2-x86_64.pkg.tar.zst
hyprlock|0.9.3-2|$ARCHIVE/h/hyprlock/hyprlock-0.9.3-2-x86_64.pkg.tar.zst
hypridle|0.1.7-8|$ARCHIVE/h/hypridle/hypridle-0.1.7-8-x86_64.pkg.tar.zst
hyprpaper|0.8.3-4|$ARCHIVE/h/hyprpaper/hyprpaper-0.8.3-4-x86_64.pkg.tar.zst
hyprpicker|0.4.6-3|$ARCHIVE/h/hyprpicker/hyprpicker-0.4.6-3-x86_64.pkg.tar.zst
hyprsunset|0.3.3-6|$ARCHIVE/h/hyprsunset/hyprsunset-0.3.3-6-x86_64.pkg.tar.zst
hyprpolkitagent|0.1.3-6|$ARCHIVE/h/hyprpolkitagent/hyprpolkitagent-0.1.3-6-x86_64.pkg.tar.zst
hyprlauncher|0.1.5-3|$ARCHIVE/h/hyprlauncher/hyprlauncher-0.1.5-3-x86_64.pkg.tar.zst
xdg-desktop-portal-hyprland|1.3.11-4|$ARCHIVE/x/xdg-desktop-portal-hyprland/xdg-desktop-portal-hyprland-1.3.11-4-x86_64.pkg.tar.zst
EOF_SPECS
)

# Packages whose versions must stay aligned with the legacy stack.
readonly PINNED_PACKAGES=(
  hyprland aquamarine hyprutils hyprgraphics hyprcursor hyprlang
  hyprtoolkit hyprwire hyprland-guiutils hyprwayland-scanner libjxl
  hyprlock hypridle hyprpaper hyprpicker hyprsunset hyprpolkitagent
  hyprlauncher xdg-desktop-portal-hyprland
)

cat <<'BANNER'

============================================================
 EndeavourOS — Hyprland legacy stack 0.54.3
============================================================
Ce script aligne les composants Hypr liés par leurs bibliothèques/ABI,
puis crée une unique directive IgnorePkg valide sous [options].

Il n'installe PAS le thème/rice complet. Waybar, Rofi, Foot, SwayNC,
et les thèmes sont gérés séparément après validation du socle.

IMPORTANT : crée d'abord un snapshot VirtualBox. Évite les mises à jour
système aveugles après avoir figé une partie d'Arch rolling release.
BANNER

printf '\nVersions actuellement installées (si présentes) :\n'
for pkg in "${PINNED_PACKAGES[@]}"; do
  pacman -Q "$pkg" 2>/dev/null || true
done

read -r -p $'\nContinuer avec cette pile historique ? [y/N] ' answer
case "${answer,,}" in
  y|yes|o|oui) ;;
  *) echo 'Annulé, aucune modification effectuée.'; exit 0 ;;
esac

URLS_TO_INSTALL=()
while IFS='|' read -r pkg target url; do
  [[ -n "$pkg" ]] || continue
  current=''
  if pacman -Q "$pkg" >/dev/null 2>&1; then
    current="$(pacman -Q "$pkg" | awk '{print $2}')"
  fi
  if [[ "$current" != "$target" ]]; then
    printf 'À aligner : %-32s actuel=%-16s cible=%s\n' "$pkg" "${current:-absent}" "$target"
    URLS_TO_INSTALL+=("$url")
  else
    printf 'OK : %-32s %s\n' "$pkg" "$target"
  fi
done <<< "$PACKAGE_SPECS"

if ((${#URLS_TO_INSTALL[@]})); then
  echo
  echo 'Installation/downgrade en une transaction pacman -U...'
  echo 'Vérifie la liste proposée par pacman, puis accepte si elle correspond.'
  sudo pacman -U "${URLS_TO_INSTALL[@]}"
else
  echo
  echo 'Les versions cibles de tous les paquets listés sont déjà installées.'
fi

# Preserve package names from existing IgnorePkg directives, but move/consolidate
# every active directive into [options], where pacman accepts it.
backup="/etc/pacman.conf.legacy-hypr-$(date +%Y%m%d-%H%M%S).bak"
sudo cp -a /etc/pacman.conf "$backup"
echo "Sauvegarde pacman.conf : $backup"
sudo python3 - <<'PY'
from pathlib import Path
import re

p = Path('/etc/pacman.conf')
lines = p.read_text(encoding='utf-8').splitlines()
ignored = set()
kept = []
for line in lines:
    m = re.match(r'^\s*IgnorePkg\s*=\s*(.*)$', line)
    if m:
        payload = m.group(1).split('#', 1)[0]
        ignored.update(payload.split())
    else:
        kept.append(line)

required = {
    'hyprland', 'aquamarine', 'hyprutils', 'hyprgraphics', 'hyprcursor', 'hyprlang',
    'hyprtoolkit', 'hyprwire', 'hyprland-guiutils', 'hyprwayland-scanner', 'libjxl',
    'hyprlock', 'hypridle', 'hyprpaper', 'hyprpicker', 'hyprsunset', 'hyprpolkitagent',
    'hyprlauncher', 'xdg-desktop-portal-hyprland',
}
ignored.update(required)
options = next((i for i, line in enumerate(kept) if line.strip() == '[options]'), None)
if options is None:
    raise SystemExit('ERREUR : section [options] introuvable; pacman.conf non modifié.')
kept.insert(options + 1, 'IgnorePkg = ' + ' '.join(sorted(ignored)))
p.write_text('\n'.join(kept) + '\n', encoding='utf-8')
PY

# Validate versions. Do not hide errors; show mismatches clearly.
echo
echo 'Directive IgnorePkg finale :'
sudo awk '
  /^\[options\][[:space:]]*$/ { in_options=1; next }
  /^\[/ { if (in_options) exit }
  in_options && /^[[:space:]]*IgnorePkg[[:space:]]*=/ { print; found=1 }
  END { if (!found) exit 1 }
' /etc/pacman.conf

echo
echo 'Vérification des versions après installation :'
failed=0
while IFS='|' read -r pkg target url; do
  [[ -n "$pkg" ]] || continue
  if ! pacman -Q "$pkg" >/dev/null 2>&1; then
    printf 'MANQUANT : %s (cible %s)\n' "$pkg" "$target"
    failed=1
    continue
  fi
  current="$(pacman -Q "$pkg" | awk '{print $2}')"
  if [[ "$current" != "$target" ]]; then
    printf 'ÉCART :   %-32s installé=%s cible=%s\n' "$pkg" "$current" "$target"
    failed=1
  else
    printf 'OK :      %-32s %s\n' "$pkg" "$current"
  fi
done <<< "$PACKAGE_SPECS"

if ((failed)); then
  echo
  echo 'ATTENTION : certains paquets restent en écart. Ne lance pas pacman -Syu.' >&2
  echo 'Copie la sortie ci-dessus pour diagnostiquer les URL/dépendances indisponibles.' >&2
  exit 2
fi

echo
echo 'Vérification Hyprland :'
Hyprland --version | head -n 20

echo
echo 'Terminé. Ne lance pas pacman -Syu avant d’avoir choisi une stratégie de maintenance.'
echo 'Pour vérifier les paquets verrouillés : pacman -Q hyprland aquamarine hyprutils hyprgraphics hyprcursor hyprlang'
