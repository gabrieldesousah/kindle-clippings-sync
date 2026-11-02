#!/bin/bash
# Lint: shellcheck em todos os scripts e validacao dos plists gerados pelo install.sh
# (com e sem o helper de IOKit), usando plutil, xmllint ou python3, o que existir.
set -u
cd "$(dirname "$0")/.." || exit 1
rc=0
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x bin/kindle-clippings-sync.sh install.sh uninstall.sh tests/*.sh \
    tests/fakes/ioreg tests/fakes/mtp-* tests/fakes/brew tests/fakes/kcs-iokit-trigger tests/fakes/kcs-mtp-pull || rc=1
else
  echo "shellcheck nao encontrado; pulando"
fi

if command -v python3 >/dev/null 2>&1; then
  for f in lib/kcs_highlights.py tests/fixtures/make-kindle-hl.py tests/fakes/pylib/kfxlib/__init__.py; do
    python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$f" || { echo "erro de sintaxe: $f"; rc=1; }
  done
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kcs-lint.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
validate() {
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$1" || return 1
  fi
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$1" || return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" <<'PY' || return 1
import plistlib, sys
plistlib.load(open(sys.argv[1], "rb"))
try:
    from lxml import etree
    import urllib.request
    dtd = etree.DTD(urllib.request.urlopen("https://www.apple.com/DTDs/PropertyList-1.0.dtd", timeout=10))
    ok = dtd.validate(etree.parse(sys.argv[1]))
    print(sys.argv[1].split("/")[-4] + ": DTD da Apple " + ("OK" if ok else "FALHOU " + str(dtd.error_log)))
    sys.exit(0 if ok else 1)
except ImportError:
    print(sys.argv[1] + ": plistlib OK (lxml ausente, DTD nao verificado)")
except Exception as e:  # sem rede
    print(sys.argv[1] + ": plistlib OK (DTD nao verificado: %s)" % e)
PY
  fi
}
for mode in sem-helper com-helper; do
  H="$TMP/$mode"
  mkdir -p "$H"
  extra=""
  [ "$mode" = com-helper ] && extra="--helper-bin tests/fakes/kcs-iokit-trigger"
  # shellcheck disable=SC2086
  env HOME="$H" KCS_SKIP_LAUNCHCTL=1 bash install.sh $extra >/dev/null 2>&1 || { echo "install.sh falhou ($mode)"; rc=1; continue; }
  validate "$H/Library/LaunchAgents/digital.gabriel.kindle-clippings-sync.plist" || rc=1
done
exit "$rc"
