#!/bin/bash
# Remove o LaunchAgent e o script instalado.
# Nunca apaga nada do cofre do Obsidian (copias, backups e a nota ficam).
#
# Uso: ./uninstall.sh [--purge] [--prefix DIR]
#   --purge       tambem apaga config, estado interno e log
#   --prefix DIR  onde o script foi instalado (padrao: ~/.local/bin)

set -eu

LABEL="digital.gabriel.kindle-clippings-sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PREFIX="${KCS_PREFIX:-$HOME/.local/bin}"
PURGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --prefix) PREFIX="${2:?--prefix precisa de um diretorio}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opcao desconhecida: $1" >&2; exit 2 ;;
  esac
done

if [ "${KCS_SKIP_LAUNCHCTL:-0}" != 1 ] && command -v launchctl >/dev/null 2>&1; then
  echo "==> Descarregando do launchd"
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 ||
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
fi

echo "==> Removendo $PLIST e $PREFIX/kindle-clippings-sync"
rm -f "$PLIST" "$PREFIX/kindle-clippings-sync"
rm -rf "$HOME/.local/libexec/kindle-clippings-sync"

if [ "$PURGE" = 1 ]; then
  echo "==> Removendo config, estado e log"
  rm -rf "$HOME/.config/kindle-clippings-sync" \
    "$HOME/Library/Application Support/kindle-clippings-sync"
  rm -f "$HOME/Library/Logs/kindle-clippings-sync.log" "$HOME/Library/Logs/kindle-clippings-sync.log.1"
fi

echo "Desinstalado. Os arquivos no cofre do Obsidian foram mantidos."
