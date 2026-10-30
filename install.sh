#!/bin/sh
# Copies the Hearthlog addon into a WoW client's AddOns folder.
# Usage: ./install.sh [era|forever|retail|all]   (default: era)
# Works with macOS /bin/sh (no bash 4 features).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
WOW="${WOW_DIR:-/Applications/World of Warcraft}"
target="${1:-era}"

sub_for() {
  case "$1" in
    era) echo "_classic_era_" ;;
    forever) echo "_forever_" ;;
    retail) echo "_retail_" ;;
    *) echo "unknown target: $1" >&2; exit 1 ;;
  esac
}

install_one() {
  dest="$WOW/$1/Interface/AddOns/Hearthlog"
  mkdir -p "$dest"
  rsync -a --delete --exclude '.DS_Store' "$HERE/Hearthlog/" "$dest/"
  echo "installed -> $dest"
}

if [ "$target" = "all" ]; then
  for k in era forever retail; do
    sub="$(sub_for "$k")"
    [ -d "$WOW/$sub" ] && install_one "$sub"
  done
else
  install_one "$(sub_for "$target")"
fi
