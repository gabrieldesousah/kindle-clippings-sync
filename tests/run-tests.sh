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
trap '[ -n "${KEEP:-}" ] || rm -rf "$TMP"' EXIT

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
FAKES="$REPO_DIR/tests/fakes"
ln -s "$FAKES/ioreg" "$TMP/fakebin/ioreg" # so o ioreg vai para o PATH; os mtp-* nao
export PATH="$TMP/fakebin:$PATH"
export FAKE_DIR="$TMP/fake"
mkdir -p "$FAKE_DIR"
echo none >"$FAKE_DIR/ioreg-mode"

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

echo "== Modo /Volumes (Kindle com armazenamento USB); ioreg sem Kindle =="
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

echo
echo "== Modo MTP (Kindle Paperwhite 1949:9981, sem /Volumes) =="
# Ambiente separado: outro estado, outro destino, sem volumes.
MDEST="$TMP/mtp-dest"
MSTATE="$TMP/mtp-state"
MDEV="$TMP/mtp-device"
mkdir -p "$MDEV" "$TMP/no-volumes"
mrun() {
  env KCS_VOLUMES_ROOT="$TMP/no-volumes" KCS_DEST="$MDEST" KCS_STATE_DIR="$MSTATE" \
    KCS_MTP_BIN_DIR="$FAKES" KCS_MTP_PULL="${MP:-}" KCS_MTP_DELAY=0 KCS_MTP_RETRIES="${MR:-3}" KCS_MTP_RETRY_INTERVAL=0 \
    KCS_MTP_TIMEOUT="${MT:-20}" KCS_MTP_POSTCHECK_DELAY=0 bash "$SCRIPT" "$@" </dev/null >"$TMP/stdout" 2>"$TMP/stderr"
}
mcalls() { grep -c -E '^(mtp-|kcs-mtp-pull)' "$FAKE_DIR/calls" 2>/dev/null || true; }
npulls() { grep -c '^kcs-mtp-pull' "$FAKE_DIR/calls" 2>/dev/null || true; }
mbackups() { find "$MDEST/backups" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }

# Aparelho falso: o arquivo certo esta em /documents; ha copias-isca em outras pastas.
{
  printf '\xef\xbb\xbf'
  entry "Livro MTP" "Destaque A."
  entry "Livro MTP" "Destaque B."
} >"$MDEV/clippings-real.txt"
printf 'isca\r\n==========\r\n' >"$MDEV/clippings-isca1.txt"
printf 'isca 2\r\n==========\r\n==========\r\n' >"$MDEV/clippings-isca2.txt"
printf 'fake' >"$MDEV/guide.azw3"
printf '5.17.1' >"$MDEV/version.txt"
T="$(printf '\t')"
cat >"$FAKE_DIR/manifest" <<MAN
101${T}3${T}Kindle_Users_Guide.azw3${T}$MDEV/guide.azw3
120${T}10${T}My Clippings.txt${T}$MDEV/clippings-isca1.txt
121${T}9${T}My Clippings.txt${T}$MDEV/clippings-isca2.txt
130${T}3${T}My Clippings.txt${T}$MDEV/clippings-real.txt
140${T}5${T}version.txt${T}$MDEV/version.txt
MAN
cat >"$FAKE_DIR/folders" <<FOL
2${T}audible
3${T}documents
8${T}  Downloads
9${T}backup
10${T}  documents
4${T}fonts
5${T}system
11${T}  thumbnails
FOL

echo "M1) ioreg sem Kindle: nao abre o MTP"
echo none >"$FAKE_DIR/ioreg-mode"; : >"$FAKE_DIR/calls"
mrun; rc=$?
check "sai com 0 e em silencio" bash -c '[ "$1" -eq 0 ] && [ ! -s "$2" ]' _ "$rc" "$TMP/stdout"
check "ioreg consultado no plano IOUSB" grep -q '^ioreg -p IOUSB' "$FAKE_DIR/calls"
check "nenhuma chamada mtp-*" [ "$(mcalls)" -eq 0 ]

echo "M2) Kindle conectado via MTP"
echo kindle >"$FAKE_DIR/ioreg-mode"; echo 1111 >"$FAKE_DIR/session"; : >"$FAKE_DIR/calls"
mrun; rc=$?
check "sai com 0" [ "$rc" -eq 0 ]
check "copia o arquivo de /documents byte a byte (nao as iscas)" cmp -s "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"
check "uma unica sessao MTP (kcs-mtp-pull), sem mtp-files/mtp-getfile" bash -c '[ "$(grep -c "^kcs-mtp-pull" "$1")" -eq 1 ] && ! grep -q "^mtp-" "$1"' _ "$FAKE_DIR/calls"
check "log registra o item 130 de /documents" grep -q 'baixado via MTP numa sessão: item 130, [0-9]* bytes, /documents/My Clippings.txt' "$LOG"
check "1 backup" [ "$(mbackups)" -eq 1 ]
check "nota conta 2 entradas" grep -q '^entradas: 2$' "$MDEST/Kindle Sync.md"
check "nota indica origem MTP" grep -q 'origem: "MTP (Kindle Paperwhite): documents/My Clippings.txt"' "$MDEST/Kindle Sync.md"
check "notificacao com 2 destaques" bash -c 'tail -n1 "$1" | grep -q "Kindle sincronizado: 2 destaques"' _ "$NOTIFY_LOG"
check "log menciona deteccao MTP" grep -q 'Kindle Paperwhite detectado via USB/MTP' "$LOG"
check "log mostra os flags sem o reset (0x10000000)" grep -q 'baixado via MTP numa sessão: .*\[0x08008106\]' "$LOG"
check "log confirma que o Kindle continua no USB" grep -q 'Kindle Paperwhite continua no USB depois da sessão MTP' "$LOG"
check "temporarios removidos" bash -c '[ -z "$(ls -d "${TMPDIR:-/tmp}"/kcs-mtp.* 2>/dev/null)" ]'
check "lock liberado" [ ! -e "$MSTATE/lock" ]

echo "M3) Mesmo evento de novo (mesma conexao): barato, sem MTP"
: >"$FAKE_DIR/calls"; n0="$(nnotify)"
mrun; rc=$?
check "sai com 0" [ "$rc" -eq 0 ]
check "nenhuma chamada mtp-*" [ "$(mcalls)" -eq 0 ]
check "nenhuma notificacao" [ "$(nnotify)" -eq "$n0" ]

echo "M4) Reconectado (novo sessionID) sem mudancas"
echo 2222 >"$FAKE_DIR/session"; : >"$FAKE_DIR/calls"
mrun; rc=$?
check "abre o MTP de novo (uma sessao)" [ "$(npulls)" -eq 1 ]
check "nenhum backup novo" [ "$(mbackups)" -eq 1 ]
check "nenhuma notificacao" [ "$(nnotify)" -eq "$n0" ]
check "log diz 'sem alterações'" grep -q 'sem alterações (MTP' "$LOG"

echo "M5) Reconectado com destaque novo"
entry "Livro MTP" "Destaque C." >>"$MDEV/clippings-real.txt"
echo 3333 >"$FAKE_DIR/session"
mrun
check "copia atualizada" cmp -s "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"
check "2 backups" [ "$(mbackups)" -eq 2 ]
check "nota conta 3 entradas" grep -q '^entradas: 3$' "$MDEST/Kindle Sync.md"

echo "M6) MTP ocupado por outro app nas 2 primeiras tentativas"
entry "Livro MTP" "Destaque D." >>"$MDEV/clippings-real.txt"
echo 4444 >"$FAKE_DIR/session"; echo 2 >"$FAKE_DIR/busy"
MR=3 mrun; rc=$?
check "sai com 0 depois de tentar de novo" [ "$rc" -eq 0 ]
check "copia atualizada" cmp -s "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"
check "log explica que o Kindle estava ocupado" grep -q 'Kindle ocupado ou indisponível via MTP (tentativa 1/3)' "$LOG"
check "log inclui a mensagem do libusb" grep -q 'reports device is busy' "$LOG"

echo "M7) MTP ocupado o tempo todo"
entry "Livro MTP" "Destaque E." >>"$MDEV/clippings-real.txt"
echo 5555 >"$FAKE_DIR/session"; echo 99 >"$FAKE_DIR/busy"; n0="$(nnotify)"
MR=2 mrun; rc=$?
check "sai com erro" [ "$rc" -ne 0 ]
check "nao altera a copia" bash -c '! cmp -s "$1" "$2"' _ "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"
check "log orienta a fechar o Android File Transfer" grep -q 'Feche Android File Transfer' "$LOG"
check "notifica uma vez" bash -c '[ "$1" -eq $(($2 + 1)) ] && tail -n1 "$3" | grep -q "ocupado"' _ "$(nnotify)" "$n0" "$NOTIFY_LOG"
: >"$FAKE_DIR/calls"
MR=3 mrun
check "proxima rodada (StartInterval) tenta de novo, mas uma vez so" [ "$(npulls)" -eq 1 ]
check "mas nao notifica de novo na mesma conexao" [ "$(nnotify)" -eq $((n0 + 1)) ]
echo 0 >"$FAKE_DIR/busy"
mrun
check "quando o app solta o aparelho, sincroniza" cmp -s "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"

echo "M8) mtp-getfile responde 'No devices.' sem baixar nada"
entry "Livro MTP" "Destaque F." >>"$MDEV/clippings-real.txt"
echo 6666 >"$FAKE_DIR/session"; touch "$FAKE_DIR/getfile-nodev"
MR=2 mrun; rc=$?
rm -f "$FAKE_DIR/getfile-nodev"
check "sai com erro e nao finge sucesso" bash -c '[ "$1" -ne 0 ] && ! cmp -s "$2" "$3"' _ "$rc" "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"
mrun
check "depois funciona normalmente" cmp -s "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"

echo "M9) Comando mtp-* travado (timeout)"
echo 7777 >"$FAKE_DIR/session"; touch "$FAKE_DIR/hang"
t0="$(date +%s)"
MR=1 MT=1 mrun; rc=$?
t1="$(date +%s)"
rm -f "$FAKE_DIR/hang"
check "sai com erro" [ "$rc" -ne 0 ]
check "nao espera os 30 s do travamento" [ $((t1 - t0)) -lt 10 ]
check "log registra o timeout" grep -q 'kcs-mtp-pull excedeu 1s' "$LOG"

echo "M10) Aparelho sem My Clippings.txt"
cp "$FAKE_DIR/manifest" "$TMP/manifest.bak"
grep -v 'My Clippings' "$TMP/manifest.bak" >"$FAKE_DIR/manifest"
echo 8888 >"$FAKE_DIR/session"
mrun; rc=$?
check "sai com 0" [ "$rc" -eq 0 ]
check "log explica" grep -q 'My Clippings.txt não existe no Kindle Paperwhite' "$LOG"
mv "$TMP/manifest.bak" "$FAKE_DIR/manifest"

echo "M11) libmtp ausente"
echo 9999 >"$FAKE_DIR/session"; mkdir -p "$TMP/empty-bin"
env KCS_VOLUMES_ROOT="$TMP/no-volumes" KCS_DEST="$MDEST" KCS_STATE_DIR="$MSTATE" \
  KCS_MTP_BIN_DIR="$TMP/empty-bin" bash "$SCRIPT" </dev/null >/dev/null 2>&1; rc=$?
check "sai com erro" [ "$rc" -ne 0 ]
check "log manda rodar brew install libmtp" grep -q 'Rode: brew install libmtp' "$LOG"
check "notifica com a instrucao" bash -c 'tail -n1 "$1" | grep -q "brew install libmtp"' _ "$NOTIFY_LOG"

echo "M12) Ferramentas achadas pelo PATH (sem KCS_MTP_BIN_DIR)"
echo 1212 >"$FAKE_DIR/session"; : >"$FAKE_DIR/calls"
env PATH="$FAKES:$PATH" KCS_VOLUMES_ROOT="$TMP/no-volumes" KCS_DEST="$MDEST" KCS_STATE_DIR="$MSTATE" \
  KCS_MTP_DELAY=0 bash "$SCRIPT" </dev/null >/dev/null 2>&1; rc=$?
check "sai com 0 e usa o kcs-mtp-pull do PATH" bash -c '[ "$1" -eq 0 ] && grep -q "^kcs-mtp-pull" "$2"' _ "$rc" "$FAKE_DIR/calls"

echo "M13) KCS_SOURCE=volumes ignora o MTP; --now forca nova leitura"
: >"$FAKE_DIR/calls"
KCS_SOURCE=volumes mrun
check "nenhuma chamada mtp-*" [ "$(mcalls)" -eq 0 ]
mrun --now
check "--now abre o MTP mesmo na mesma conexao" [ "$(mcalls)" -ge 1 ]

echo "M14a) Reserva sem kcs-mtp-pull: ferramentas mtp-* (3 sessoes)"
entry "Livro MTP" "Destaque G." >>"$MDEV/clippings-real.txt"
echo 1414 >"$FAKE_DIR/session"; : >"$FAKE_DIR/calls"
MP=none mrun; rc=$?
check "sai com 0" [ "$rc" -eq 0 ]
check "usa mtp-files e mtp-getfile do item 130" bash -c 'grep -q "^mtp-files" "$1" && grep -q "^mtp-getfile 130 " "$1" && ! grep -q "^kcs-mtp-pull" "$1"' _ "$FAKE_DIR/calls"
check "copia atualizada" cmp -s "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"
check "log avisa do risco das 3 sessoes" grep -q 'kcs-mtp-pull não encontrado' "$LOG"

echo "M14b) Varios disparos ao mesmo tempo (eventos de IOKit repetidos): uma sessao MTP so"
entry "Livro MTP" "Destaque H." >>"$MDEV/clippings-real.txt"
echo 1515 >"$FAKE_DIR/session"; : >"$FAKE_DIR/calls"; b0="$(mbackups)"
for _ in 1 2 3 4; do FAKE_PULL_DELAY=1 mrun & done
wait
check "exatamente uma sessao MTP" [ "$(npulls)" -eq 1 ]
check "exatamente um backup novo" [ "$(mbackups)" -eq $((b0 + 1)) ]
check "copia atualizada" cmp -s "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"
: >"$FAKE_DIR/calls"
FAKE_PULL_DELAY=1 mrun
check "disparo depois da sincronizacao nao abre o MTP" [ "$(mcalls)" -eq 0 ]

echo "M14c) SIGTERM ignorado herdado (como vinha do helper de IOKit)"
entry "Livro MTP" "Destaque I." >>"$MDEV/clippings-real.txt"
echo 1616 >"$FAKE_DIR/session"
t0="$(date +%s)"
env KCS_VOLUMES_ROOT="$TMP/no-volumes" KCS_DEST="$MDEST" KCS_STATE_DIR="$MSTATE" KCS_MTP_BIN_DIR="$FAKES" \
  KCS_MTP_DELAY=0 KCS_MTP_RETRY_INTERVAL=0 KCS_MTP_TIMEOUT=60 \
  bash -c 'trap "" TERM; exec bash "$1"' _ "$SCRIPT" </dev/null >/dev/null 2>&1; rc=$?
t1="$(date +%s)"
check "comando rapido nao espera o timeout de 60 s" bash -c '[ "$1" -eq 0 ] && [ "$2" -lt 15 ]' _ "$rc" $((t1 - t0))
check "copia atualizada" cmp -s "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"
echo 1717 >"$FAKE_DIR/session"; touch "$FAKE_DIR/hang"
t0="$(date +%s)"
env KCS_VOLUMES_ROOT="$TMP/no-volumes" KCS_DEST="$MDEST" KCS_STATE_DIR="$MSTATE" KCS_MTP_BIN_DIR="$FAKES" \
  KCS_MTP_DELAY=0 KCS_MTP_RETRIES=1 KCS_MTP_TIMEOUT=1 \
  bash -c 'trap "" TERM; exec bash "$1"' _ "$SCRIPT" </dev/null >/dev/null 2>&1
t1="$(date +%s)"
rm -f "$FAKE_DIR/hang"
check "comando travado que ignora TERM e encerrado com KILL" [ $((t1 - t0)) -lt 15 ]
check "lock liberado" [ ! -e "$MSTATE/lock" ]

echo "M14d) KCS_MTP_PULL_ARGS=--no-release-interface"
entry "Livro MTP" "Destaque J." >>"$MDEV/clippings-real.txt"
echo 1818 >"$FAKE_DIR/session"; : >"$FAKE_DIR/calls"
KCS_MTP_PULL_ARGS=--no-release-interface mrun; rc=$?
check "repassa a opcao ao kcs-mtp-pull" bash -c '[ "$1" -eq 0 ] && grep -q "^kcs-mtp-pull --no-release-interface " "$2"' _ "$rc" "$FAKE_DIR/calls"
check "log mostra o flag NO_RELEASE_INTERFACE" grep -q '\[0x08008146\]' "$LOG"

echo "M14) Kindle MTP tem prioridade sobre um volume montado"
: >"$FAKE_DIR/calls"
env KCS_VOLUMES_ROOT="$VOLS" KCS_DEST="$MDEST" KCS_STATE_DIR="$MSTATE" KCS_MTP_BIN_DIR="$FAKES" \
  KCS_MTP_DELAY=0 bash "$SCRIPT" --force </dev/null >/dev/null 2>&1
check "copia veio do MTP" cmp -s "$MDEV/clippings-real.txt" "$MDEST/My Clippings.txt"
echo none >"$FAKE_DIR/ioreg-mode"

echo
echo "== Instalador =="
echo "M15) Destaques do banco de anotações do Kindle (firmware 5.19.6+)"
PY3="$(command -v python3 || true)"
if [ -z "$PY3" ] || ! "$PY3" -c 'import sqlite3' 2>/dev/null; then
  echo "  (pulado: sem python3 com sqlite3)"
else
  HDEST="$TMP/hl-dest"; HSTATE="$TMP/hl-state"; HCACHE="$TMP/hl-cache"
  HDEV="$FAKE_DIR/hl-dev"; HNOTES="$HDEST/Destaques"
  NOTE_A="$HNOTES/Livro Teste.md"
  AAA="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  mkhl() { rm -rf "$HDEV"; "$PY3" "$REPO_DIR/tests/fixtures/make-kindle-hl.py" "$HDEV" "$FAKE_DIR/hl-tree" "$1"; }
  hlrun() {
    env KCS_VOLUMES_ROOT="$TMP/no-volumes" KCS_DEST="$HDEST" KCS_STATE_DIR="$HSTATE" KCS_CACHE_DIR="$HCACHE" \
      KCS_MTP_BIN_DIR="$FAKES" KCS_MTP_PULL="" KCS_MTP_DELAY=0 KCS_MTP_RETRIES=1 KCS_MTP_RETRY_INTERVAL=0 \
      KCS_MTP_TIMEOUT=20 KCS_MTP_POSTCHECK_DELAY=0 KCS_HIGHLIGHTS="${HL:-1}" KCS_PYTHON="$PY3" \
      KCS_HIGHLIGHTS_PY="$REPO_DIR/lib/kcs_highlights.py" KCS_KFXLIB_PATH="${KFX-$FAKES/pylib}" \
      bash "$SCRIPT" --now </dev/null >"$TMP/stdout" 2>"$TMP/stderr"
  }
  dbbackups() { find "$HDEST/backups" -maxdepth 1 -name 'ksdk_annotation_v1 *.db' 2>/dev/null | wc -l | tr -d ' '; }
  echo kindle >"$FAKE_DIR/ioreg-mode"; echo 7777 >"$FAKE_DIR/session"; rm -f "$FAKE_DIR/busy" "$FAKE_DIR/nodevice"
  mkhl base
  devsum="$(cd "$HDEV" && find . -type f -exec cksum {} + | sort)"
  : >"$FAKE_DIR/calls"; : >"$FAKE_DIR/calls.get"; : >"$LOG"
  hlrun; rc=$?
  check "sai com 0 e sincroniza o My Clippings.txt como antes" bash -c '[ "$1" -eq 0 ] && cmp -s "$2" "$3"' _ "$rc" "$MDEV/clippings-real.txt" "$HDEST/My Clippings.txt"
  check "uma sessao so, com --list-to, --get-match (só contas amzn1.account) e --then" \
    bash -c '[ "$(grep -c "^kcs-mtp-pull" "$1")" -eq 1 ] && grep -q -- "--list-to .* --get-match /system/ksdk/.annotations/amzn1.account.\*/ksdk_annotation_v1.db .* --then " "$1"' _ "$FAKE_DIR/calls"
  check "baixa só os livros .kfx com destaques que estão no aparelho (2)" [ "$(wc -l <"$FAKE_DIR/calls.get" | tr -d ' ')" -eq 2 ]
  check "livro fica no cache, fora do cofre" bash -c '[ -f "$1/books/'"$AAA"'.kfx" ] && [ -f "$1/books/'"$AAA"'.meta" ] && ! find "$2" -name "*.kfx" | grep -q .' _ "$HCACHE" "$HDEST"
  check "uma nota por livro com destaques (3)" [ "$(find "$HNOTES" -name '*.md' | wc -l | tr -d ' ')" -eq 3 ]
  check "título sem o '(Autor)' e autor no frontmatter" bash -c 'grep -q "^titulo: \"Livro Teste\"$" "$1" && grep -q "^autor: \"Autora Fulana\"$" "$1"' _ "$NOTE_A"
  check "frontmatter: 3 destaques, 1 nota, texto verificado" bash -c 'grep -q "^destaques: 3$" "$1" && grep -q "^notas: 1$" "$1" && grep -q "^texto_verificado: true$" "$1"' _ "$NOTE_A"
  check "texto recuperado, aspas retas, sem travessão nem chamada de nota" \
    grep -qx '> Primeiro parágrafo "com" - nota.' "$NOTE_A"
  check "capítulos pelo sumário do livro" bash -c 'grep -qx "### Capítulo 1" "$1" && grep -qx "### Capítulo 2" "$1"' _ "$NOTE_A"
  check "posição e data em linha pequena" grep -q '^> <small>Posição 1-2 | ' "$NOTE_A"
  check "nota do Kindle junto do destaque, com aspas retas" grep -qx '\*\*Nota no Kindle:\*\* minha "nota"' "$NOTE_A"
  check "destaque sobre imagem indicado" grep -q 'destaque sobre uma imagem' "$NOTE_A"
  check "anonymous ignorado (sem o destaque 99)" bash -c '! grep -rq "highlight-99" "$1" && ! grep -q "Primeiro p\$" "$2"' _ "$HSTATE/highlights" "$NOTE_A"
  check "livro com DRM: só posições, com o motivo" bash -c 'f="$(grep -l "^kindle_id: DDDD" "$1"/*.md)" && grep -q "^texto_verificado: false$" "$f" && grep -q "protegido" "$f" && grep -q "posição no livro 5-9" "$f"' _ "$HNOTES"
  check "livro ausente do aparelho: só posições" bash -c 'f="$(grep -l "^kindle_id: MMMM" "$1"/*.md)" && grep -q "livro não encontrado no Kindle" "$f"' _ "$HNOTES"
  check "cópia do banco em backups/" [ "$(dbbackups)" -eq 1 ]
  check "log resume os destaques" grep -q 'destaques: 3 livro(s), 6 anotações (6 novas), 3 nota(s) atualizada(s)' "$LOG"
  check "nada escrito no aparelho" [ "$(cd "$HDEV" && find . -type f -exec cksum {} + | sort)" = "$devsum" ]

  mtime_a="$(ls -l --time-style=+%s "$NOTE_A" 2>/dev/null || stat -f %m "$NOTE_A")"
  sleep 1; : >"$FAKE_DIR/calls.get"; : >"$LOG"
  hlrun; rc=$?
  check "2a execução sem mudanças: 0 livros baixados de novo" bash -c '[ "$1" -eq 0 ] && [ ! -s "$2" ]' _ "$rc" "$FAKE_DIR/calls.get"
  check "2a execução: nota não reescrita, sem novo backup do banco" bash -c '[ "$(ls -l --time-style=+%s "$1" 2>/dev/null || stat -f %m "$1")" = "$2" ] && [ "$3" -eq 1 ]' _ "$NOTE_A" "$mtime_a" "$(dbbackups)"
  check "2a execução: log com 0 novas e 0 notas atualizadas" grep -q '(0 novas), 0 nota(s) atualizada(s)' "$LOG"

  mkhl edit; : >"$LOG"
  hlrun
  check "destaque alterado no Kindle (mesmo id, nova data): nota atualizada" bash -c 'grep -q "^> <small>Posição 3-4 | " "$1" && [ "$(grep -c "<small>Posição 3" "$1")" -eq 1 ]' _ "$NOTE_A"
  check "banco mudou: novo backup" [ "$(dbbackups)" -eq 2 ]

  mkhl delete
  hlrun
  check "destaque apagado no Kindle: mantido e marcado" bash -c 'grep -q "removido no Kindle" "$1" && grep -q "^removidos_no_kindle: 1$" "$1" && grep -q "^destaques: 2$" "$1"' _ "$NOTE_A"

  mkhl newbook; : >"$FAKE_DIR/calls.get"
  hlrun
  check "livro mudou no aparelho (data): baixado de novo" grep -q 'Livro Teste' "$FAKE_DIR/calls.get"
  check "texto novo do livro na nota" grep -q 'REVISADO' "$NOTE_A"

  rm -rf "$HSTATE/highlights" "$HNOTES"
  KFX="$TMP/sem-kfxlib" hlrun
  check "sem kfxlib: notas só com posições e motivo" bash -c 'grep -q "kfxlib não instalado" "$1" && grep -q "^texto_verificado: false$" "$1"' _ "$NOTE_A"

  : >"$FAKE_DIR/calls"
  HL=0 hlrun
  check "KCS_HIGHLIGHTS=0: sessão sem extras" bash -c '! grep -q -- "--then" "$1"' _ "$FAKE_DIR/calls"
  rm -rf "$HDEV" "$FAKE_DIR/hl-tree"
fi

echo "12) install.sh / uninstall.sh (HOME falso, sem launchctl, sem libmtp, sem helper)"
IHOME="$TMP/ihome"
mkdir -p "$IHOME"
IVAULT="$IHOME/Library/Mobile Documents/iCloud~md~obsidian/Documents"
IPATH="$TMP/ibin:/usr/bin:/bin" # PATH sem mtp-* e sem brew
mkdir -p "$TMP/ibin"
# KCS_TOOL_DIRS vazio: nao procura em /opt/homebrew/bin nem /usr/local/bin (o Mac real pode ter libmtp).
ienv() { env -u KCS_VAULT -u KCS_DEST_SUBDIR -u KCS_CONFIG HOME="$IHOME" PATH="$IPATH" KCS_TOOL_DIRS="" KCS_SKIP_LAUNCHCTL=1 \
  KCS_PY_CANDIDATES="" KCS_KFXLIB_SRC="$FAKES/pylib" KCS_PY_DEPS_SKIP=1 "$@"; } # sem rede, sem python do sistema
IPLIST="$IHOME/Library/LaunchAgents/digital.gabriel.kindle-clippings-sync.plist"
ICFG="$IHOME/.config/kindle-clippings-sync/config.env"
plist_ok() {
  if command -v plutil >/dev/null 2>&1; then plutil -lint "$1" >/dev/null
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$1"
  elif command -v xmllint >/dev/null 2>&1; then xmllint --noout "$1"
  else true; fi
}
plist_get() { # plist_get arquivo expressao-python (d = dicionario do plist)
  python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(eval(sys.argv[2]))' "$1" "$2"
}
cfg() { bash -c '. "$1"; eval "printf %s \"\$$2\""' _ "$ICFG" "$1"; }
ienv KCS_HELPER_BUILD=0 bash "$REPO_DIR/install.sh" >"$TMP/install.out" 2>&1; rc=$? # sem compilar o helper
check "install.sh sai com 0" [ "$rc" -eq 0 ]
check "avisa que falta o libmtp e mostra o comando" grep -q 'brew install libmtp' "$TMP/install.out"
check "script instalado e executavel" [ -x "$IHOME/.local/bin/kindle-clippings-sync" ]
check "plist gerado" [ -f "$IPLIST" ]
check "plist valido" plist_ok "$IPLIST"
check "plist sem placeholders" bash -c '! grep -q "__[A-Z_]*__" "$1"' _ "$IPLIST"
check "sem libmtp: kcs-mtp-pull nao instalado" [ ! -e "$IHOME/.local/libexec/kindle-clippings-sync/kcs-mtp-pull" ]
if command -v python3 >/dev/null 2>&1; then
  check "StartOnMount true" [ "$(plist_get "$IPLIST" 'd["StartOnMount"]')" = True ]
  check "StartInterval 120" [ "$(plist_get "$IPLIST" 'd["StartInterval"]')" = 120 ]
  check "sem helper: sem LaunchEvents (evita relancamento em loop)" [ "$(plist_get "$IPLIST" '"LaunchEvents" in d')" = False ]
  check "sem helper: roda /bin/bash direto" \
    [ "$(plist_get "$IPLIST" 'd["ProgramArguments"]')" = "['/bin/bash', '$IHOME/.local/bin/kindle-clippings-sync']" ]
  check "PATH do job inclui /opt/homebrew/bin" bash -c 'case "$1" in /opt/homebrew/bin:*) true ;; *) false ;; esac' _ "$(plist_get "$IPLIST" 'd["EnvironmentVariables"]["PATH"]')"
fi
check "config preserva o caminho com espacos e til" [ "$(cfg KCS_VAULT)" = "$IVAULT" ]
check "config tem pasta padrao" [ "$(cfg KCS_DEST_SUBDIR)" = "05 Conhecimento/Leituras/_Kindle" ]
check "config tem o produto USB padrao (0x9981)" [ "$(cfg KCS_USB_PRODUCT_ID)" = 39297 ]
ILIBEXEC="$IHOME/.local/libexec/kindle-clippings-sync"
check "extrator de destaques instalado em libexec" [ -f "$ILIBEXEC/kcs_highlights.py" ]
check "kfxlib instalado fora do repo, com SOURCE.txt (commit fixo, GPL v3)" \
  bash -c '[ -f "$1/kfxlib/kfxlib/__init__.py" ] && grep -q "^Commit: [0-9a-f]\{40\}$" "$1/kfxlib/SOURCE.txt" && grep -q "GNU General Public License v3.0" "$1/kfxlib/SOURCE.txt"' _ "$ILIBEXEC"
check "sem python3: avisa e segue" grep -q 'nao achei python3 >= 3.9' "$TMP/install.out"
check "config: KCS_HIGHLIGHTS=auto e KCS_PYTHON no venv" bash -c '[ "$1" = auto ] && [ "$2" = "$3/venv/bin/python" ]' _ "$(cfg KCS_HIGHLIGHTS)" "$(cfg KCS_PYTHON)" "$ILIBEXEC"
check "nada do kfxlib (GPL) dentro do repositorio" bash -c '! git -C "$1" ls-files | grep -v "^tests/fakes/pylib/" | grep -qi kfxlib/' _ "$REPO_DIR"

echo "13) Com helper de IOKit (--helper-bin) e libmtp no PATH"
mkdir -p "$TMP/ibrew"
for t in mtp-files mtp-folders mtp-getfile mtp-common.sh; do ln -sf "$FAKES/$t" "$TMP/ibrew/$t"; done
IPATH="$TMP/ibrew:/usr/bin:/bin"
ienv bash "$REPO_DIR/install.sh" --helper-bin "$FAKES/kcs-iokit-trigger" --pull-bin "$FAKES/kcs-mtp-pull" >"$TMP/install.out" 2>&1; rc=$?
check "install.sh sai com 0" [ "$rc" -eq 0 ]
check "kcs-mtp-pull instalado" [ -x "$IHOME/.local/libexec/kindle-clippings-sync/kcs-mtp-pull" ]
check "encontra o libmtp" grep -q "ok: $TMP/ibrew/mtp-files" "$TMP/install.out"
IHELPER="$IHOME/.local/libexec/kindle-clippings-sync/kcs-iokit-trigger"
check "helper instalado" [ -x "$IHELPER" ]
check "instalador informa o kcs-mtp-pull" grep -q 'kcs-mtp-pull' "$TMP/install.out"
check "plist valido" plist_ok "$IPLIST"
if command -v python3 >/dev/null 2>&1; then
  M='d["LaunchEvents"]["com.apple.iokit.matching"]["digital.gabriel.kindle-clippings-sync.usb"]'
  check "LaunchEvents IOProviderClass IOUSBHostDevice" [ "$(plist_get "$IPLIST" "${M}[\"IOProviderClass\"]")" = IOUSBHostDevice ]
  check "idVendor 6473 (0x1949)" [ "$(plist_get "$IPLIST" "${M}[\"idVendor\"]")" = 6473 ]
  check "idProduct 39297 (0x9981)" [ "$(plist_get "$IPLIST" "${M}[\"idProduct\"]")" = 39297 ]
  check "IOMatchLaunchStream true" [ "$(plist_get "$IPLIST" "${M}[\"IOMatchLaunchStream\"]")" = True ]
  check "helper e o primeiro argumento" \
    [ "$(plist_get "$IPLIST" 'd["ProgramArguments"]')" = "['$IHELPER', '/bin/bash', '$IHOME/.local/bin/kindle-clippings-sync']" ]
  check "StartInterval continua como reserva" [ "$(plist_get "$IPLIST" 'd["StartInterval"]')" = 120 ]
fi
ienv bash "$REPO_DIR/install.sh" --helper-bin "$FAKES/kcs-iokit-trigger" --product-id any --interval 300 \
  --dest-subdir "Outra Pasta/Kindle" >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
  check "--product-id any: casa so o idVendor" [ "$(plist_get "$IPLIST" "\"idProduct\" in $M")" = False ]
  check "--interval 300" [ "$(plist_get "$IPLIST" 'd["StartInterval"]')" = 300 ]
fi
check "reinstalar com --dest-subdir atualiza a config" [ "$(cfg KCS_DEST_SUBDIR)" = "Outra Pasta/Kindle" ]
ienv bash "$REPO_DIR/install.sh" --helper-bin "$FAKES/kcs-iokit-trigger" >/dev/null 2>&1; rc=$?
check "reinstalar sem opcoes funciona" [ "$rc" -eq 0 ]
check "reinstalar sem opcoes preserva a config" \
  bash -c '[ "$1" = "Outra Pasta/Kindle" ] && [ "$2" = any ] && [ "$3" = 300 ]' _ "$(cfg KCS_DEST_SUBDIR)" "$(cfg KCS_USB_PRODUCT_ID)" "$(cfg KCS_START_INTERVAL)"
ienv bash "$REPO_DIR/install.sh" --no-iokit --interval 0 >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
  check "--no-iokit remove LaunchEvents" [ "$(plist_get "$IPLIST" '"LaunchEvents" in d')" = False ]
  check "--interval 0 remove StartInterval" [ "$(plist_get "$IPLIST" '"StartInterval" in d')" = False ]
fi

echo "14) --install-deps usa o Homebrew"
IPATH="$TMP/ibin2:/usr/bin:/bin"
mkdir -p "$TMP/ibin2"; ln -sf "$FAKES/brew" "$TMP/ibin2/brew"
: >"$FAKE_DIR/calls"
ienv FAKE_BREW_PREFIX="$TMP/ibin2" FAKE_TOOLS_DIR="$FAKES" bash "$REPO_DIR/install.sh" --install-deps >"$TMP/install.out" 2>&1; rc=$?
check "install.sh sai com 0" [ "$rc" -eq 0 ]
check "rodou brew install libmtp" grep -q '^brew install libmtp$' "$FAKE_DIR/calls"
ienv bash "$REPO_DIR/install.sh" --install-deps >/dev/null 2>&1
check "segunda vez nao reinstala" [ "$(grep -c '^brew install' "$FAKE_DIR/calls")" -eq 1 ]

echo "14b) Extrator de destaques: venv proprio e --no-highlights"
PY3I="$(command -v python3 || true)"
if [ -n "$PY3I" ] && "$PY3I" -m venv --help >/dev/null 2>&1; then
  ienv KCS_PY_BASE="$PY3I" bash "$REPO_DIR/install.sh" --pull-bin "$FAKES/kcs-mtp-pull" >"$TMP/install.out" 2>&1; rc=$?
  if grep -q 'falha ao criar o venv' "$TMP/install.out"; then
    echo "  (venv indisponivel neste python; checagens do venv puladas)"
  else
    check "cria o venv em libexec com o python escolhido" bash -c '[ "$1" -eq 0 ] && [ -x "$2/venv/bin/python" ] && [ "$(cat "$2/venv/.kcs-base")" = "$3" ]' _ "$rc" "$ILIBEXEC" "$PY3I"
    check "kfxlib importa com o python do venv" grep -q 'ok: kfxlib importa' "$TMP/install.out"
    check "KCS_PY_DEPS_SKIP=1: sem pip" bash -c '! grep -q "pip (so no venv)" "$1"' _ "$TMP/install.out"
    ienv KCS_PY_BASE="$PY3I" bash "$REPO_DIR/install.sh" --pull-bin "$FAKES/kcs-mtp-pull" >"$TMP/install.out" 2>&1
    check "reinstalar mantem o venv" grep -q 'python: ' "$TMP/install.out"
  fi
fi
ienv bash "$REPO_DIR/install.sh" --no-highlights >"$TMP/install.out" 2>&1; rc=$?
check "--no-highlights grava KCS_HIGHLIGHTS=0" bash -c '[ "$1" -eq 0 ] && [ "$2" = 0 ] && grep -q "desligados" "$3"' _ "$rc" "$(cfg KCS_HIGHLIGHTS)" "$TMP/install.out"
ienv bash "$REPO_DIR/install.sh" >/dev/null 2>&1
check "reinstalar sem opcoes preserva KCS_HIGHLIGHTS=0" [ "$(cfg KCS_HIGHLIGHTS)" = 0 ]
ienv KCS_HIGHLIGHTS=auto bash "$REPO_DIR/install.sh" >/dev/null 2>&1
check "KCS_HIGHLIGHTS=auto no ambiente religa" [ "$(cfg KCS_HIGHLIGHTS)" = auto ]

echo "15) Script instalado + helper + config gerada, ponta a ponta"
mkdir -p "$IVAULT"
echo kindle >"$FAKE_DIR/ioreg-mode"; echo 4242 >"$FAKE_DIR/session"
IPATH="$TMP/ibrew:$TMP/fakebin:/usr/bin:/bin"
ienv bash "$REPO_DIR/install.sh" --helper-bin "$FAKES/kcs-iokit-trigger" --pull-bin "$FAKES/kcs-mtp-pull" --dest-subdir "05 Conhecimento/Leituras/_Kindle" >/dev/null 2>&1
ienv KCS_MTP_DELAY=0 "$IHELPER" /bin/bash "$IHOME/.local/bin/kindle-clippings-sync" </dev/null >/dev/null 2>&1; rc=$?
check "roda pelo helper com a config instalada" bash -c '[ "$1" -eq 0 ] && cmp -s "$2" "$3"' _ "$rc" "$MDEV/clippings-real.txt" "$IVAULT/05 Conhecimento/Leituras/_Kindle/My Clippings.txt"
check "usou o kcs-mtp-pull instalado (uma sessao)" grep -q 'baixado via MTP numa sessão' "$IHOME/Library/Logs/kindle-clippings-sync.log"
echo none >"$FAKE_DIR/ioreg-mode"

echo "16) uninstall.sh"
ienv bash "$REPO_DIR/uninstall.sh" >/dev/null 2>&1; rc=$?
check "uninstall.sh sai com 0" [ "$rc" -eq 0 ]
check "plist removido" [ ! -e "$IPLIST" ]
check "script removido" [ ! -e "$IHOME/.local/bin/kindle-clippings-sync" ]
check "helper removido" [ ! -e "$IHELPER" ]
check "venv e kfxlib removidos" bash -c '[ ! -e "$1/venv" ] && [ ! -e "$1/kfxlib" ]' _ "$ILIBEXEC"
mkdir -p "$IHOME/Library/Caches/kindle-clippings-sync/books"
check "cache de livros mantido sem --purge" [ -d "$IHOME/Library/Caches/kindle-clippings-sync" ]
check "config mantida sem --purge" [ -f "$ICFG" ]
check "cofre intacto" [ -f "$IVAULT/05 Conhecimento/Leituras/_Kindle/My Clippings.txt" ]
ienv bash "$REPO_DIR/uninstall.sh" --purge >/dev/null 2>&1
check "--purge remove a config" [ ! -e "$ICFG" ]
check "--purge remove o cache de livros" [ ! -e "$IHOME/Library/Caches/kindle-clippings-sync" ]

echo "17) kcs-mtp-pull (C) contra um libmtp falso (tests/stub-libmtp)"
STUB="$REPO_DIR/tests/stub-libmtp"
CCMD=""
if [ "$(uname -s)" = Darwin ] && xcrun --find clang >/dev/null 2>&1; then CCMD="xcrun clang"
elif command -v cc >/dev/null 2>&1; then CCMD="cc"; fi
if [ -z "$CCMD" ]; then
  echo "  (pulado: sem compilador C)"
else
  KMP="$TMP/kmp"; KD="$TMP/kmp-out"; KLOG="$TMP/kmp-log"; mkdir -p "$KD"
  # shellcheck disable=SC2086 # CCMD pode ser "xcrun clang"
  $CCMD -O2 -Wall -Werror -I"$STUB" -o "$KMP" "$REPO_DIR/helper/kcs-mtp-pull.c" "$STUB/libmtp-stub.c" >"$TMP/kmp-build.log" 2>&1
  check "compila sem avisos contra o stub" [ -x "$KMP" ]
  BOOK="/documents/Downloads/Items01/Livro Comço_ID1"
  kmp() { STUB_LOG="$KLOG" "$KMP" "$@"; }

  : >"$KLOG"; kmp "$KD/clip.txt" >"$TMP/kmp.out" 2>"$TMP/kmp.err"; rc=$?
  check "modo padrao: baixa /documents/My Clippings.txt" bash -c '[ "$1" -eq 0 ] && grep -q "^OK 10 40 /documents/My Clippings.txt$" "$2" && [ "$(wc -c <"$3" | tr -d " ")" -eq 40 ]' _ "$rc" "$TMP/kmp.out" "$KD/clip.txt"
  check "modo padrao: reset desligado ao abrir (0x08008106)" grep -q '^open 0x08008106$' "$KLOG"

  : >"$KLOG"; kmp --list >"$TMP/kmp.out" 2>"$TMP/kmp.err"; rc=$?
  check "--list sai com 0 e lista os 20 itens" bash -c '[ "$1" -eq 0 ] && [ "$(wc -l <"$2" | tr -d " ")" -eq 20 ]' _ "$rc" "$TMP/kmp.out"
  check "--list: tipo, id, pai, storage, bytes, mtime, caminho completo" \
    grep -qx "$(printf 'f\t24\t23\t65537\t21\t1790000024\t%s.sdr/Livro_ID1abc.yjr' "$BOOK")" "$TMP/kmp.out"
  check "--list: pastas com d e pai 0 na raiz" grep -qx "$(printf 'd\t2\t0\t65537\t0\t1790000002\t/system')" "$TMP/kmp.out"
  check "--list: nada baixado" bash -c '! grep -q "^get" "$1"' _ "$KLOG"

  : >"$KLOG"; rm -rf "$KD"; mkdir -p "$KD/sdr"
  kmp --get "$BOOK.kfx" "$KD/book.kfx" --get-dir "$BOOK.sdr" "$KD/sdr" --get-id 30 "$KD/v.txt" >"$TMP/kmp.out" 2>"$TMP/kmp.err"; rc=$?
  check "--get/--get-dir/--get-id numa so chamada saem com 0" [ "$rc" -eq 0 ]
  check "uma unica sessao (1 open, 1 release)" bash -c '[ "$(grep -c "^open" "$1")" -eq 1 ] && [ "$(grep -c "^release" "$1")" -eq 1 ]' _ "$KLOG"
  check "--get pelo caminho (com acento) baixa o arquivo certo" bash -c 'head -c 8 "$1" | grep -q "item 22" && [ "$(wc -c <"$1" | tr -d " ")" -eq 100 ]' _ "$KD/book.kfx"
  check "--get-dir baixa so os arquivos diretos da pasta" bash -c '[ -f "$1/Livro_ID1abc.yjr" ] && [ -f "$1/Livro_ID1abc.yjf" ] && [ ! -e "$1/inner.bin" ] && [ "$(ls "$1" | wc -l | tr -d " ")" -eq 2 ]' _ "$KD/sdr"
  check "--get-id baixa pelo id" bash -c 'head -c 7 "$1" | grep -q "item 30"' _ "$KD/v.txt"
  check "imprime GOT por arquivo" [ "$(grep -c '^GOT ' "$TMP/kmp.out")" -eq 4 ]

  # Sessao completa da sincronizacao: clippings + arvore + bancos + o que o --then pedir.
  : >"$KLOG"; rm -rf "$KD"; mkdir -p "$KD"
  cat >"$KD/sel.sh" <<'SEL'
#!/bin/sh
# seletor falso: confere a arvore e pede o livro e um caminho inexistente
grep -q "Livro_ID1abc.yjr" "$KCS_TREE" || exit 5
printf 'GET\t%s\t%s\n' "/documents/Downloads/Items01/Livro Comço_ID1.kfx" "$KCS_OUT/livros/ID1.kfx.new"
printf 'ruido que deve ser ignorado\n'
SEL
  chmod +x "$KD/sel.sh"
  KCS_OUT="$KD" kmp "$KD/clip.txt" --list-to "$KD/tree.tsv" \
    --get-match '/system/ksdk/.annotations/amzn1.account.*/ksdk_annotation_v1.db' "$KD/dev" \
    --then "$KD/sel.sh" >"$TMP/kmp.out" 2>"$TMP/kmp.err"; rc=$?
  check "sincronizacao completa: sai com 0 e baixa o My Clippings.txt" bash -c '[ "$1" -eq 0 ] && grep -q "^OK 10 40 " "$2" && [ -f "$3" ]' _ "$rc" "$TMP/kmp.out" "$KD/clip.txt"
  check "--list-to grava a arvore em arquivo, nao no stdout" bash -c '[ "$(wc -l <"$1" | tr -d " ")" -eq 20 ] && ! grep -q "^f	" "$2"' _ "$KD/tree.tsv" "$TMP/kmp.out"
  check "--get-match baixa o banco da conta e pula o anonymous" bash -c '[ -f "$1/system/ksdk/.annotations/amzn1.account.TESTE/ksdk_annotation_v1.db" ] && [ ! -e "$1/system/ksdk/.annotations/anonymous" ]' _ "$KD/dev"
  check "--then baixa o que o programa pediu (criando a pasta)" bash -c 'head -c 7 "$1" | grep -q "item 22"' _ "$KD/livros/ID1.kfx.new"
  check "--then: tudo numa sessao (1 open, 1 release)" bash -c '[ "$(grep -c "^open" "$1")" -eq 1 ] && [ "$(grep -c "^release" "$1")" -eq 1 ]' _ "$KLOG"
  cat >"$KD/sel2.sh" <<'SEL'
#!/bin/sh
printf 'GET\t/nao/existe\t/tmp/x\n'
exit 3
SEL
  chmod +x "$KD/sel2.sh"
  kmp "$KD/clip2.txt" --list-to "$KD/tree2.tsv" --then "$KD/sel2.sh" >"$TMP/kmp.out" 2>"$TMP/kmp.err"; rc=$?
  check "erro no --then nao muda o codigo do My Clippings.txt (0) e aparece como ERR" bash -c '[ "$1" -eq 0 ] && grep -q "^ERR nao encontrado: /nao/existe" "$2" && grep -q "^ERR then: " "$2"' _ "$rc" "$TMP/kmp.err"
  kmp --then >/dev/null 2>&1; rc=$?
  check "--then sem argumento: uso (64)" [ "$rc" -eq 64 ]

  kmp --get /nao/existe "$KD/x" >"$TMP/kmp.out" 2>"$TMP/kmp.err"; rc=$?
  check "--get de caminho inexistente: sai com 1 e ERR" bash -c '[ "$1" -eq 1 ] && grep -q "^ERR nao encontrado: /nao/existe" "$2"' _ "$rc" "$TMP/kmp.err"
  kmp --get /documents "$KD/x" >"$TMP/kmp.out" 2>"$TMP/kmp.err"; rc=$?
  check "--get de pasta: sai com 1 sem criar arquivo" bash -c '[ "$1" -eq 1 ] && [ ! -e "$2" ]' _ "$rc" "$KD/x"
  STUB_MODE=failget kmp --get-id 30 "$KD/y" >/dev/null 2>"$TMP/kmp.err"; rc=$?
  check "falha de download: sai com 1 e ERR download" bash -c '[ "$1" -eq 1 ] && grep -q "^ERR download 30" "$2"' _ "$rc" "$TMP/kmp.err"
  STUB_MODE=nodevice kmp --list >/dev/null 2>&1; rc=$?
  check "sem aparelho: sai com 2" [ "$rc" -eq 2 ]
  STUB_MODE=nostorage kmp --list >/dev/null 2>&1; rc=$?
  check "sem storage (bloqueado): sai com 2" [ "$rc" -eq 2 ]
  kmp --get "$KD/x" >/dev/null 2>&1; rc=$?
  check "--get sem 2 argumentos: uso (64)" [ "$rc" -eq 64 ]
  kmp >/dev/null 2>&1; rc=$?
  check "sem argumentos: uso (64)" [ "$rc" -eq 64 ]
fi

echo
echo "Resultado: $PASS ok, $FAIL falhas"
[ "$FAIL" -eq 0 ]
