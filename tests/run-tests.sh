#!/bin/bash
# shellcheck disable=SC2016,SC1112
# Testes do kindle-clippings-sync. Rodam em Linux ou macOS, sem tocar no
# sistema real: criam um /Volumes falso, um cofre falso e um HOME falso.
#
# Uso: tests/run-tests.sh

set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/bin/kindle-clippings-sync.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { # check "descricao" comando...
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else ko "$desc"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kcs-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
VOLS="$TMP/Volumes"
VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents"
SUBDIR="05 Conhecimento/Leituras/_Kindle"
DEST="$VAULT/$SUBDIR"
NOTIFY_LOG="$TMP/notifications.log"
mkdir -p "$HOME" "$VOLS" "$VAULT" "$TMP/fakebin"

# osascript falso: registra a notificacao em vez de mostrar.
cat >"$TMP/fakebin/osascript" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" >>"$NOTIFY_LOG"
FAKE
chmod +x "$TMP/fakebin/osascript"
export PATH="$TMP/fakebin:$PATH"

export KCS_VOLUMES_ROOT="$VOLS"
export KCS_VAULT="$VAULT"
export KCS_DEST_SUBDIR="$SUBDIR"
export KCS_MOUNT_DELAY=0
export KCS_RETRIES=1
export KCS_RETRY_INTERVAL=0
export KCS_NOTIFY=1
export KCS_CONFIG="$TMP/nao-existe.env"
LOG="$HOME/Library/Logs/kindle-clippings-sync.log"
STATE="$HOME/Library/Application Support/kindle-clippings-sync"

run() { bash "$SCRIPT" "$@" </dev/null >"$TMP/stdout" 2>"$TMP/stderr"; }
nbackups() { find "$DEST/backups" -maxdepth 1 -type f -name 'My Clippings *.txt' 2>/dev/null | wc -l | tr -d ' '; }
nnotify() { [ -f "$NOTIFY_LOG" ] && wc -l <"$NOTIFY_LOG" | tr -d ' ' || echo 0; }

# Gera uma entrada no formato do Kindle (CRLF).
entry() {
  printf '%s\r\n' "$1 (Autor Exemplo)" \
    "- Seu destaque na página 12 | posição 180-182 | Adicionado: segunda-feira, 2 de novembro de 2026 10:00:00" \
    "" "$2" "=========="
}

KINDLE="$VOLS/Kindle"
mkdir -p "$KINDLE/documents" "$KINDLE/system"
CLIP="$KINDLE/documents/My Clippings.txt"
{
  printf '\xef\xbb\xbf'
  entry "Livro Um" "Primeiro destaque com acentuação: ação, coração."
  entry "Livro Um" "Segundo destaque."
  entry "Livro Dois" "Terceiro destaque."
} >"$CLIP.staged"

echo "1) Sem Kindle conectado"
# Um pendrive qualquer com o mesmo caminho, mas sem marcador de Kindle: deve ser ignorado.
mkdir -p "$VOLS/AAA USB/documents"
printf 'nao sou kindle\r\n==========\r\n' >"$VOLS/AAA USB/documents/My Clippings.txt"
run; rc=$?
check "sai com 0" [ "$rc" -eq 0 ]
check "nao imprime nada" bash -c '[ ! -s "$1" ] && [ ! -s "$2" ]' _ "$TMP/stdout" "$TMP/stderr"
check "nao cria destino" [ ! -e "$DEST" ]
check "nao notifica" [ "$(nnotify)" -eq 0 ]

echo "2) Primeira sincronizacao (BOM + CRLF)"
mv "$CLIP.staged" "$CLIP"
run; rc=$?
check "sai com 0" [ "$rc" -eq 0 ]
check "copia identica byte a byte" cmp -s "$CLIP" "$DEST/My Clippings.txt"
check "BOM preservado" [ "$(head -c 3 "$DEST/My Clippings.txt" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]
check "CRLF preservado" grep -q $'\r$' "$DEST/My Clippings.txt"
check "1 backup criado" [ "$(nbackups)" -eq 1 ]
check "nome do backup no formato 'My Clippings YYYY-MM-DD HHMMSS.txt'" \
  bash -c 'ls "$1" | grep -Eq "^My Clippings [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{6}\.txt$"' _ "$DEST/backups"
check "backup identico" cmp -s "$CLIP" "$(find "$DEST/backups" -type f | head -n1)"
NOTE="$DEST/Kindle Sync.md"
check "nota existe" [ -f "$NOTE" ]
check "nota comeca com frontmatter YAML" [ "$(head -n1 "$NOTE")" = "---" ]
check "frontmatter tem tags" grep -q '^tags:$' "$NOTE"
check "frontmatter tem ultima_sincronizacao" grep -Eq '^ultima_sincronizacao: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$NOTE"
check "frontmatter conta 3 entradas" grep -q '^entradas: 3$' "$NOTE"
check "nota em portugues" grep -q 'Última sincronização' "$NOTE"
check "nota sem travessao, setas, aspas curvas ou reticencias" \
  bash -c '! grep -q -e "—" -e "–" -e "→" -e "←" -e "⇒" -e "“" -e "”" -e "‘" -e "’" -e "…" "$1"' _ "$NOTE"
check "notificacao 'Kindle sincronizado: 3 destaques'" grep -q 'Kindle sincronizado: 3 destaques' "$NOTIFY_LOG"
check "log registra sincronizacao" grep -q 'sincronizado: 3 entradas' "$LOG"
check "pendrive sem marcador ignorado" bash -c '! grep -q "AAA USB" "$1"' _ "$LOG"
check "nada de arquivo temporario sobrando" bash -c '[ -z "$(find "$1" -name "*.tmp.*")" ]' _ "$DEST"

echo "3) Rodar de novo sem mudancas"
NOTE_SUM="$(cksum <"$NOTE")"
run; rc=$?
check "sai com 0" [ "$rc" -eq 0 ]
check "nenhum backup novo" [ "$(nbackups)" -eq 1 ]
check "nota inalterada" [ "$(cksum <"$NOTE")" = "$NOTE_SUM" ]
check "nenhuma notificacao nova" [ "$(nnotify)" -eq 1 ]
check "log diz 'sem alterações'" grep -q 'sem alterações' "$LOG"

echo "4) Novo destaque no Kindle"
entry "Livro Dois" "Quarto destaque." >>"$CLIP"
run; rc=$?
check "sai com 0" [ "$rc" -eq 0 ]
check "copia atualizada" cmp -s "$CLIP" "$DEST/My Clippings.txt"
check "2 backups (mesmo no mesmo segundo)" [ "$(nbackups)" -eq 2 ]
check "nota conta 4 entradas" grep -q '^entradas: 4$' "$NOTE"
check "notificacao com 4 destaques" grep -q 'Kindle sincronizado: 4 destaques' "$NOTIFY_LOG"

echo "5) Lock contra execucoes concorrentes"
mkdir -p "$STATE/lock"
sleep 300 & HOLDER=$!
echo "$HOLDER" >"$STATE/lock/pid"
entry "Livro Tres" "Quinto destaque." >>"$CLIP"
run; rc=$?
check "sai com 0 quando outra execucao segura o lock" [ "$rc" -eq 0 ]
check "nao copia enquanto o lock esta ativo" bash -c '! cmp -s "$1" "$2"' _ "$CLIP" "$DEST/My Clippings.txt"
check "log registra execucao concorrente" grep -q 'outra execução em andamento' "$LOG"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
echo 999999 >"$STATE/lock/pid"
run; rc=$?
check "lock obsoleto e removido e a copia acontece" cmp -s "$CLIP" "$DEST/My Clippings.txt"
check "lock liberado ao final" [ ! -e "$STATE/lock" ]

echo "6) Execucoes simultaneas de verdade"
entry "Livro Tres" "Sexto destaque." >>"$CLIP"
before="$(nbackups)"
for _ in 1 2 3 4 5; do bash "$SCRIPT" </dev/null >/dev/null 2>&1 & done
wait
check "copia final correta" cmp -s "$CLIP" "$DEST/My Clippings.txt"
check "exatamente 1 backup novo" [ "$(nbackups)" -eq $((before + 1)) ]

echo "7) Copia apagada no cofre e restaurada mesmo sem mudanca no Kindle"
rm -f "$DEST/My Clippings.txt"
run
check "copia restaurada" cmp -s "$CLIP" "$DEST/My Clippings.txt"

echo "8) Singular e --force"
mkdir -p "$TMP/v2/Kindle/documents" "$TMP/v2/Kindle/system"
entry "Livro" "Unico." >"$TMP/v2/Kindle/documents/My Clippings.txt"
KCS_VOLUMES_ROOT="$TMP/v2" KCS_DEST="$TMP/dest2" KCS_STATE_DIR="$TMP/state2" run
check "notificacao no singular" grep -q 'Kindle sincronizado: 1 destaque"' "$NOTIFY_LOG"
KCS_VOLUMES_ROOT="$TMP/v2" KCS_DEST="$TMP/dest2" KCS_STATE_DIR="$TMP/state2" run --force
check "--force cria backup mesmo sem mudanca" [ "$(find "$TMP/dest2/backups" -type f | wc -l | tr -d ' ')" -eq 2 ]

echo "9) Marcador tolerante (volume com outro nome e .kindle)"
mkdir -p "$TMP/v3/MEU LEITOR/documents"
touch "$TMP/v3/MEU LEITOR/.kindle"
entry "Livro" "X." >"$TMP/v3/MEU LEITOR/documents/My Clippings.txt"
KCS_VOLUMES_ROOT="$TMP/v3" KCS_DEST="$TMP/dest3" KCS_STATE_DIR="$TMP/state3" run
check "volume com .kindle e aceito" [ -f "$TMP/dest3/My Clippings.txt" ]

echo "10) Config via arquivo (caminho com espacos e til)"
CFG="$TMP/cfg.env"
VAULT2="$TMP/Outro Cofre~teste/Documents"
mkdir -p "$VAULT2"
printf "KCS_VAULT='%s'\nKCS_DEST_SUBDIR='Leituras/Kindle'\n" "$VAULT2" >"$CFG"
env -u KCS_VAULT -u KCS_DEST_SUBDIR KCS_CONFIG="$CFG" KCS_STATE_DIR="$TMP/state4" \
  bash "$SCRIPT" </dev/null >/dev/null 2>&1
check "destino lido do arquivo de config" cmp -s "$CLIP" "$VAULT2/Leituras/Kindle/My Clippings.txt"

echo "11) Cofre inexistente"
env KCS_VAULT="$TMP/nao/existe" KCS_STATE_DIR="$TMP/state5" bash "$SCRIPT" </dev/null >/dev/null 2>&1; rc=$?
check "sai com erro" [ "$rc" -ne 0 ]
check "nao cria o cofre" [ ! -e "$TMP/nao" ]

echo "12) install.sh / uninstall.sh (HOME falso, sem launchctl)"
IHOME="$TMP/ihome"
mkdir -p "$IHOME"
IVAULT="$IHOME/Library/Mobile Documents/iCloud~md~obsidian/Documents"
ienv() { env -u KCS_VAULT -u KCS_DEST_SUBDIR -u KCS_CONFIG HOME="$IHOME" KCS_SKIP_LAUNCHCTL=1 "$@"; }
ienv bash "$REPO_DIR/install.sh" >"$TMP/install.out" 2>&1; rc=$?
check "install.sh sai com 0" [ "$rc" -eq 0 ]
IPLIST="$IHOME/Library/LaunchAgents/digital.gabriel.kindle-clippings-sync.plist"
ICFG="$IHOME/.config/kindle-clippings-sync/config.env"
check "script instalado e executavel" [ -x "$IHOME/.local/bin/kindle-clippings-sync" ]
check "plist gerado" [ -f "$IPLIST" ]
check "plist sem placeholders" bash -c '! grep -q "__[A-Z]*__" "$1"' _ "$IPLIST"
check "plist tem StartOnMount true" bash -c 'grep -A1 "<key>StartOnMount</key>" "$1" | grep -q "<true/>"' _ "$IPLIST"
check "plist aponta para o script instalado" grep -q "<string>$IHOME/.local/bin/kindle-clippings-sync</string>" "$IPLIST"
if command -v xmllint >/dev/null 2>&1; then
  check "plist e XML valido (xmllint)" xmllint --noout "$IPLIST"
elif command -v plutil >/dev/null 2>&1; then
  check "plist valido (plutil)" plutil -lint "$IPLIST"
elif command -v python3 >/dev/null 2>&1; then
  check "plist valido (python plistlib)" python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$IPLIST"
fi
check "config preserva o caminho com espacos e til" \
  bash -c '. "$1"; [ "$KCS_VAULT" = "$2" ]' _ "$ICFG" "$IVAULT"
check "config tem pasta padrao" bash -c '. "$1"; [ "$KCS_DEST_SUBDIR" = "05 Conhecimento/Leituras/_Kindle" ]' _ "$ICFG"
ienv bash "$REPO_DIR/install.sh" --dest-subdir "Outra Pasta/Kindle" >/dev/null 2>&1
check "reinstalar com --dest-subdir atualiza a config" bash -c '. "$1"; [ "$KCS_DEST_SUBDIR" = "Outra Pasta/Kindle" ]' _ "$ICFG"
ienv bash "$REPO_DIR/install.sh" >/dev/null 2>&1; rc=$?
check "reinstalar sem opcoes funciona" [ "$rc" -eq 0 ]
check "reinstalar sem opcoes preserva a config" bash -c '. "$1"; [ "$KCS_DEST_SUBDIR" = "Outra Pasta/Kindle" ]' _ "$ICFG"
ienv bash "$REPO_DIR/uninstall.sh" >/dev/null 2>&1; rc=$?
check "uninstall.sh sai com 0" [ "$rc" -eq 0 ]
check "plist removido" [ ! -e "$IPLIST" ]
check "script removido" [ ! -e "$IHOME/.local/bin/kindle-clippings-sync" ]
check "config mantida sem --purge" [ -f "$ICFG" ]
ienv bash "$REPO_DIR/uninstall.sh" --purge >/dev/null 2>&1
check "--purge remove a config" [ ! -e "$ICFG" ]

echo
echo "Resultado: $PASS ok, $FAIL falhas"
[ "$FAIL" -eq 0 ]
