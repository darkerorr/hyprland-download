#!/usr/bin/env bash
# Configuration-only rollback for the assistant-generated Hyprland/Cyber/Glass rice scripts.
# It deliberately DOES NOT remove packages, disable services, or edit /etc/pacman.conf.
set -u
IFS=$'\n\t'

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    -h|--help)
      cat <<'HELP'
Usage: ./rollback-hyprland-design.sh [--dry-run|--apply]

Default is preview-only. Pass --apply to restore the design/configuration files.

This script only rolls back configuration/design changes recorded by the earlier
assistant-generated installers, plus files explicitly marked CYBER-RICE or Glass/
Hyprland-Components managed blocks. It creates a timestamped copy of the current
state before changing any path.

It does NOT remove installed packages, stop/disable services, remove Hyprland,
change the login shell automatically, or edit /etc/pacman.conf. The Hyprland
version locks in pacman.conf are intentionally left untouched.
HELP
      exit 0 ;;
    *) echo "Option inconnue: $arg" >&2; exit 2 ;;
  esac
done

if (( EUID == 0 )); then
  echo "Lance ce script comme utilisateur normal, pas avec sudo." >&2
  exit 2
fi
command -v sudo >/dev/null 2>&1 || { echo "sudo est nécessaire pour restaurer certains fichiers système." >&2; exit 2; }

STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
UNDO_DIR="$STATE_HOME/hyprland-design-rollback/$STAMP"
LOG="$UNDO_DIR/rollback.log"
mkdir -p "$UNDO_DIR/current/home" "$UNDO_DIR/current/system"
chmod 700 "$UNDO_DIR" "$UNDO_DIR/current"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n[DESIGN-ROLLBACK] %s\n' "$*"; }
warn() { printf '[AVERTISSEMENT] %s\n' "$*" >&2; }

if (( APPLY )); then
  say "MODE APPLIQUÉ. Les fichiers remplacés/supprimés seront copiés dans : $UNDO_DIR/current"
  echo "Aucun paquet ne sera désinstallé et aucun service ne sera arrêté/désactivé."
  read -r -p 'Continuer et restaurer les configurations ? [o/N] ' answer || exit 1
  [[ "${answer,,}" == o || "${answer,,}" == oui || "${answer,,}" == y || "${answer,,}" == yes ]] || { echo 'Annulé.'; exit 0; }
else
  say "MODE APERÇU : aucun changement. Pour appliquer, relance avec --apply."
fi

safe_user_path() {
  case "$1" in
    "$HOME"/.config/*|"$HOME"/.local/bin/*|"$HOME"/.local/share/*|"$HOME"/.local/state/*|"$HOME"/.zshrc|"$HOME"/.vimrc|"$HOME"/.bashrc|"$HOME"/.profile|"$HOME"/.xprofile|"$HOME"/.gtkrc-2.0|"$HOME"/Pictures/Wallpapers/*|"$HOME"/Pictures/Screenshots/*|"$HOME"/Videos/Recordings/*|"$HOME"/Media/Hyprland/*) return 0 ;;
    *) return 1 ;;
  esac
}
safe_system_path() {
  case "$1" in
    /etc/vconsole.conf|/etc/X11/xorg.conf.d/00-keyboard.conf|/etc/sddm.conf|/etc/sddm.conf.d/99-hyprland-glass-mono.conf|/usr/share/sddm/themes/hyprland-glass-mono/*) return 0 ;;
    /etc/pacman.conf) return 1 ;; # do not touch the user's Hyprland package locks
    *) return 1 ;;
  esac
}

save_current() {
  local path="$1" system="$2" dest rel
  if [[ "$system" == 1 ]]; then
    rel="${path#/}"
    dest="$UNDO_DIR/current/system/$rel"
    if sudo test -e "$path" || sudo test -L "$path"; then
      mkdir -p "$(dirname "$dest")"
      sudo cp -a -- "$path" "$dest" || return 1
      sudo chown -R "$(id -u):$(id -g)" "$UNDO_DIR/current/system" 2>/dev/null || true
    fi
  else
    rel="${path#"$HOME"/}"
    dest="$UNDO_DIR/current/home/$rel"
    if [[ -e "$path" || -L "$path" ]]; then
      mkdir -p "$(dirname "$dest")"
      cp -a -- "$path" "$dest" || return 1
    fi
  fi
}

restore_one() {
  local action="$1" path="$2" backup="${3:--}" system=0
  [[ -n "$action" && -n "$path" ]] || return 0
  case "$action" in
    EXISTING|NEW) system=0; safe_user_path "$path" || { warn "Chemin utilisateur hors périmètre, ignoré : $path"; return 0; } ;;
    EXISTING_SYSTEM|NEW_SYSTEM) system=1; safe_system_path "$path" || { warn "Chemin système hors périmètre (notamment pacman.conf), ignoré : $path"; return 0; } ;;
    *) return 0 ;;
  esac

  if [[ "$action" == EXISTING || "$action" == EXISTING_SYSTEM ]]; then
    if [[ "$backup" == '-' ]] || { [[ ! -e "$backup" && ! -L "$backup" ]]; }; then
      warn "Sauvegarde absente, fichier non modifié : $path"
      return 0
    fi
    if (( ! APPLY )); then echo "[APERÇU] Restaurer $path depuis $backup"; return 0; fi
    save_current "$path" "$system" || { warn "Impossible de créer la copie de sécurité de $path"; return 0; }
    if (( system )); then
      sudo rm -rf -- "$path" || { warn "Impossible de remplacer $path"; return 0; }
      sudo mkdir -p -- "$(dirname "$path")"
      sudo cp -a -- "$backup" "$path" || { warn "Restauration échouée : $path"; return 0; }
    else
      rm -rf -- "$path" || { warn "Impossible de remplacer $path"; return 0; }
      mkdir -p -- "$(dirname "$path")"
      cp -a -- "$backup" "$path" || { warn "Restauration échouée : $path"; return 0; }
    fi
    echo "Restauré : $path"
  elif [[ "$action" == NEW || "$action" == NEW_SYSTEM ]]; then
    if [[ ! -e "$path" && ! -L "$path" ]]; then return 0; fi
    if (( ! APPLY )); then echo "[APERÇU] Retirer le chemin créé par l'installateur : $path"; return 0; fi
    save_current "$path" "$system" || { warn "Impossible de créer une copie de sécurité de $path"; return 0; }
    if (( system )); then sudo rm -rf -- "$path" || { warn "Impossible de retirer $path"; return 0; }
    else rm -rf -- "$path" || { warn "Impossible de retirer $path"; return 0; }; fi
    echo "Retiré (copie conservée dans $UNDO_DIR/current) : $path"
  fi
}

restore_manifest() {
  local manifest="$1" label="$2" action path backup marker
  [[ -r "$manifest" ]] || return 0
  marker="$manifest.design-rollback-done"
  if [[ -e "$marker" ]]; then echo "Déjà traité : $label"; return 0; fi
  say "Manifeste : $label"
  # Reverse line order to undo later changes first if a file was tracked more than once.
  tac "$manifest" | while IFS=$'\t' read -r action path backup; do
    [[ -n "${action:-}" && -n "${path:-}" ]] || continue
    restore_one "$action" "$path" "${backup:--}"
  done
  if (( APPLY )); then : > "$marker"; fi
}

sorted_dirs_desc() {
  [[ -d "$1" ]] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -type d -print | sort -r
}

# Restore newest rice configs first, then the older component installer manifests.
GLASS_ROOT="$STATE_HOME/glass-mono-rice"
while IFS= read -r run; do
  [[ -n "$run" ]] || continue
  restore_manifest "$run/manifest.tsv" "Glass Mono $(basename "$run")"
done < <(sorted_dirs_desc "$GLASS_ROOT/runs")

COMP_ROOT="$STATE_HOME/hyprland-components"
while IFS= read -r run; do
  [[ -n "$run" ]] || continue
  restore_manifest "$COMP_ROOT/backups/$(basename "$run")/manifest.tsv" "Hyprland Components $(basename "$run")"
done < <(sorted_dirs_desc "$COMP_ROOT/runs")

# Older Cyber-Rice script did not use the same manifest format. Restore its explicit
# pre-install copies when found. Intentionally do NOT restore pacman.conf: its
# IgnorePkg pinning may be protecting Hyprland 0.54.3 and must remain untouched.
CYBER_ROOT="$HOME/.config/cyber-rice-backups"
if [[ -d "$CYBER_ROOT" ]]; then
  while IFS= read -r cyber; do
    [[ -n "$cyber" ]] || continue
    [[ -e "$cyber/RESTORED_BY_DESIGN_RESET" ]] && continue
    say "Sauvegarde Cyber-Rice : $cyber"
    for name in hypr waybar rofi swaync foot kitty zsh starship fastfetch wlogout gtk-3.0; do
      src="$cyber/$name"
      dest="$HOME/.config/$name"
      [[ -e "$src" || -L "$src" ]] || continue
      if (( ! APPLY )); then echo "[APERÇU] Restaurer $dest depuis $src"; continue; fi
      save_current "$dest" 0 || { warn "Copie de sécurité impossible : $dest"; continue; }
      rm -rf -- "$dest"
      mkdir -p -- "$(dirname "$dest")"
      cp -a -- "$src" "$dest" || warn "Impossible de restaurer $dest"
      echo "Restauré depuis Cyber-Rice : $dest"
    done
    if [[ -e "$cyber/pacman.conf" ]]; then
      echo "Préservé volontairement : $cyber/pacman.conf (pacman.conf système non modifié pour garder les verrouillages Hyprland)."
    fi
    if (( APPLY )); then : > "$cyber/RESTORED_BY_DESIGN_RESET"; fi
  done < <(find "$CYBER_ROOT" -mindepth 1 -maxdepth 1 -type d -print | sort -r)
fi

# As a fallback for any unmanifested managed blocks, strip only clearly-marked blocks.
# Back up each file before editing it. This does not remove packages or whole config dirs.
strip_marked_blocks() {
  local f="$1" tmp
  grep -Iq -E 'MANAGED BY HYPRLAND COMPONENTS|GLASS MONO RICE|CYBER-RICE' "$f" 2>/dev/null || return 0
  if (( ! APPLY )); then echo "[APERÇU] Examiner/retirer les blocs marqués dans $f si présents (manifeste absent)."; return 0; fi
  # Full generated Cyber-Rice hyprland.conf is only removed when the explicit banner
  # indicates the entire file was generated and no manifest restore handled it.
  if [[ "$f" == "$HOME/.config/hypr/hyprland.conf" ]] && grep -q '^# CYBER-RICE / Hyprland' "$f"; then
    save_current "$f" 0 || { warn "Copie de sécurité impossible : $f"; return 0; }
    rm -f -- "$f"
    echo "Retiré le fichier de config généré Cyber-Rice (copie conservée) : $f"
    return 0
  fi
  save_current "$f" 0 || { warn "Copie de sécurité impossible : $f"; return 0; }
  tmp="$(mktemp "${f}.rollback.XXXXXX")" || return 0
  if ! awk '
    /^# >>> MANAGED BY HYPRLAND COMPONENTS:/ { skip=1; next }
    /^# <<< END HYPRLAND COMPONENTS:/ { skip=0; next }
    /^\/\/ >>> MANAGED BY HYPRLAND COMPONENTS:/ { skip=1; next }
    /^\/\/ <<< END HYPRLAND COMPONENTS:/ { skip=0; next }
    /^\/\* >>> MANAGED BY HYPRLAND COMPONENTS:/ { skip=1; next }
    /^\/\* <<< END HYPRLAND COMPONENTS:/ { skip=0; next }
    /^# >>> GLASS MONO RICE/ { skip=1; next }
    /^# <<< END GLASS MONO RICE/ { skip=0; next }
    /^\/\* >>> GLASS MONO RICE/ { skip=1; next }
    /^\/\* <<< END GLASS MONO RICE/ { skip=0; next }
    !skip { print }
  ' "$f" > "$tmp"; then rm -f "$tmp"; return 0; fi
  if [[ -s "$tmp" ]]; then cat "$tmp" > "$f"; else rm -f "$f"; fi
  rm -f "$tmp"
  echo "Blocs gérés retirés (autres lignes conservées) : $f"
}

if (( APPLY )); then
  for base in hypr waybar kitty tofi mako wlogout swayosd gtk-3.0 gtk-4.0 qt5ct qt6ct Kvantum starship fastfetch; do
    dir="$HOME/.config/$base"
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' f; do strip_marked_blocks "$f"; done < <(find "$dir" -type f -print0)
  done
  for f in "$HOME/.zshrc" "$HOME/.vimrc"; do [[ -f "$f" ]] && strip_marked_blocks "$f"; done
else
  for base in hypr waybar kitty tofi mako wlogout swayosd gtk-3.0 gtk-4.0 qt5ct qt6ct Kvantum starship fastfetch; do
    dir="$HOME/.config/$base"
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' f; do grep -Iq -E 'MANAGED BY HYPRLAND COMPONENTS|GLASS MONO RICE|CYBER-RICE' "$f" 2>/dev/null && echo "[APERÇU] Bloc/file marqué trouvé : $f"; done < <(find "$dir" -type f -print0)
  done
  for f in "$HOME/.zshrc" "$HOME/.vimrc"; do [[ -f "$f" ]] && grep -Iq -E 'MANAGED BY HYPRLAND COMPONENTS|GLASS MONO RICE|CYBER-RICE' "$f" 2>/dev/null && echo "[APERÇU] Bloc marqué trouvé : $f"; done
fi

# Restore the previous login shell only when a Glass manifest recorded both values.
for run in $(sorted_dirs_desc "$GLASS_ROOT/runs"); do
  rec="$run/shell.tsv"
  [[ -r "$rec" && ! -e "$rec.design-rollback-done" ]] || continue
  IFS=$'\t' read -r old_shell new_shell < "$rec" || true
  current_shell="$(getent passwd "$USER" | cut -d: -f7)"
  [[ -n "${old_shell:-}" && -n "${new_shell:-}" && "$current_shell" == "$new_shell" ]] || continue
  echo "Shell enregistré par l'installateur : $current_shell ; shell précédent : $old_shell"
  if (( APPLY )); then
    read -r -p "Restaurer le shell de connexion précédent ($old_shell) ? [o/N] " answer || answer=n
    if [[ "${answer,,}" == o || "${answer,,}" == oui || "${answer,,}" == y || "${answer,,}" == yes ]]; then
      sudo chsh -s "$old_shell" "$USER" && echo "Shell restauré : $old_shell" || warn 'Impossible de restaurer le shell précédent.'
    fi
    : > "$rec.design-rollback-done"
  else
    echo "[APERÇU] Proposerait de restaurer le shell précédent : $old_shell"
  fi
done

cat <<FINISH

Terminé.
Mode : $([[ $APPLY -eq 1 ]] && echo 'APPLIQUÉ' || echo 'APERÇU SEULEMENT')
Journal : $LOG
Copies de sécurité : $UNDO_DIR/current
Paquets : laissés installés volontairement.
Services : laissés dans leur état actuel volontairement.
/etc/pacman.conf : non modifié, pour préserver les verrouillages Hyprland.

Après le rollback, reste dans le TTY tant que tu n'as pas choisi de nouveaux dotfiles.
FINISH
