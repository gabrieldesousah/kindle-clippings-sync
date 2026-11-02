#!/bin/bash
# Lint: shellcheck nos scripts e validacao do template do plist.
set -u
cd "$(dirname "$0")/.." || exit 1
rc=0
PLIST_T="launchd/digital.gabriel.kindle-clippings-sync.plist.template"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck bin/kindle-clippings-sync.sh install.sh uninstall.sh tests/*.sh || rc=1
else
  echo "shellcheck nao encontrado; pulando"
fi
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST_T" || rc=1
elif command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$PLIST_T" || rc=1
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb")); print(sys.argv[1]+": OK")' "$PLIST_T" || rc=1
fi
exit "$rc"
