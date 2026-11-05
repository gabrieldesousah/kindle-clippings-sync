#!/bin/bash
# kindle-clippings-sync: copia "documents/My Clippings.txt" do Kindle para o
# cofre do Obsidian sempre que o Kindle e conectado ao Mac.
#
# Duas fontes, nesta ordem:
#   1. MTP (Kindles recentes, que nao montam em /Volumes): detecta o aparelho
#      com ioreg (barato) e so entao usa as ferramentas do libmtp (Homebrew).
#   2. /Volumes (Kindles antigos, armazenamento USB): procura
#      /Volumes/*/documents/My Clippings.txt.
#
# Compativel com o /bin/bash 3.2 do macOS.
#
# Uso: kindle-clippings-sync.sh [--now] [--force] [--setup-notify] [--test-notify] [--help]
#   --now           sem espera inicial e ignora o "ja sincronizado nesta conexao"
#   --force         copia mesmo que o conteudo nao tenha mudado (implica --now)
#   --setup-notify  configura o webhook do Grok Bot (URL + chave) e envia um POST de teste
#   --test-notify   reenvia um POST de teste com a config atual (sem sincronizar)
#
# Configuracao (arquivo de config ou variaveis de ambiente; o ambiente vence):
#   KCS_VAULT               cofre do Obsidian
#   KCS_DEST_SUBDIR         pasta dentro do cofre (padrao: 05 Conhecimento/Leituras/_Kindle)
#   KCS_DEST                destino absoluto (ignora KCS_VAULT/KCS_DEST_SUBDIR)
#   KCS_SOURCE              auto | mtp | volumes (padrao: auto)
#   KCS_LOG                 arquivo de log (padrao: ~/Library/Logs/kindle-clippings-sync.log)
#   KCS_STATE_DIR           estado interno: hash, sessao USB e lock
#   KCS_NOTIFY              1 notifica via osascript, 0 desliga (padrao: 1)
#   KCS_NOTIFY_URL          URL do webhook (Grok Bot routine); vazio = nao envia
#   KCS_NOTIFY_KEY          chave do webhook (nunca e logada nem impressa)
#   KCS_NOTIFY_KEY_HEADER   header da chave (padrao: Authorization -> "Bearer <chave>";
#                           outro nome, ex. X-Webhook-Key, envia a chave pura nesse header)
#   KCS_MAX_BACKUPS         manter so os N backups mais recentes; 0 = todos (padrao: 0)
#  MTP:
#   KCS_USB_VENDOR_ID       idVendor do Kindle em decimal (padrao: 6473 = 0x1949, Amazon)
#   KCS_MTP_PULL            programa de download numa sessao so (padrao: ~/.local/libexec/
#                           kindle-clippings-sync/kcs-mtp-pull; "none" usa as ferramentas mtp-*)
#   KCS_MTP_PULL_ARGS       opcoes extras do kcs-mtp-pull (ex.: --no-release-interface)
#   KCS_MTP_BIN_DIR         pasta das ferramentas mtp-* (padrao: PATH, /opt/homebrew/bin, /usr/local/bin)
#   KCS_MTP_DELAY           segundos de espera apos detectar o aparelho (padrao: 3)
#   KCS_MTP_RETRIES         tentativas se o MTP estiver ocupado (padrao: 4)
#   KCS_MTP_RETRY_INTERVAL  segundos entre tentativas (padrao: 10)
#   KCS_MTP_TIMEOUT         tempo maximo de cada comando mtp-* em segundos (padrao: 180)
#   KCS_MTP_RESYNC_SECONDS  0 = uma vez por conexao; N = de novo apos N segundos conectado (padrao: 0)
#   KCS_MTP_KILL_PTPCAMERAD 1 = encerra o ptpcamerad do macOS quando o MTP estiver ocupado (padrao: 0)
#  Destaques do banco de anotacoes do Kindle (firmware 5.19.6+ nao grava mais o
#  My Clippings.txt; so via MTP com o kcs-mtp-pull):
#   KCS_HIGHLIGHTS          auto | 1 | 0 (padrao: auto = liga se o extrator estiver instalado)
#   KCS_HIGHLIGHTS_SUBDIR   pasta das notas dentro do destino (padrao: Destaques)
#   KCS_PYTHON              python do extrator (padrao: ~/.local/libexec/kindle-clippings-sync/venv/bin/python)
#   KCS_HIGHLIGHTS_PY       extrator (padrao: ~/.local/libexec/kindle-clippings-sync/kcs_highlights.py)
#   KCS_KFXLIB_PATH         pasta que contem o pacote kfxlib (padrao: ~/.local/libexec/kindle-clippings-sync/kfxlib)
#   KCS_CACHE_DIR           cache dos livros baixados (padrao: ~/Library/Caches/kindle-clippings-sync)
#  /Volumes:
#   KCS_VOLUMES_ROOT        raiz dos volumes (padrao: /Volumes)
#   KCS_MOUNT_DELAY         segundos de espera apos uma montagem recente (padrao: 5)
#   KCS_RETRIES             tentativas de encontrar o arquivo (padrao: 3)
#   KCS_RETRY_INTERVAL      segundos entre tentativas (padrao: 5)
#   KCS_MOUNT_WINDOW        so espera/tenta de novo se /Volumes mudou ha menos de N s (padrao: 90)
#   KCS_REQUIRE_MARKER      1 exige marcador de Kindle no volume (padrao: 1)
#   KCS_CONFIG              arquivo de config (padrao: ~/.config/kindle-clippings-sync/config.env)

set -u
umask 022

VERSION="2.0.0"
CLIPPINGS_NAME="My Clippings.txt"
CLIPPINGS_REL="documents/$CLIPPINGS_NAME"

CONFIG_VARS="KCS_VAULT KCS_DEST_SUBDIR KCS_DEST KCS_SOURCE KCS_LOG KCS_STATE_DIR KCS_NOTIFY \
KCS_NOTIFY_URL KCS_NOTIFY_KEY KCS_NOTIFY_KEY_HEADER \
KCS_MAX_BACKUPS KCS_USB_VENDOR_ID KCS_MTP_PULL KCS_MTP_PULL_ARGS KCS_MTP_BIN_DIR KCS_MTP_DELAY KCS_MTP_RETRIES \
KCS_MTP_RETRY_INTERVAL KCS_MTP_TIMEOUT KCS_MTP_RESYNC_SECONDS KCS_MTP_KILL_PTPCAMERAD \
KCS_VOLUMES_ROOT KCS_MOUNT_DELAY KCS_RETRIES KCS_RETRY_INTERVAL KCS_MOUNT_WINDOW KCS_REQUIRE_MARKER \
KCS_HIGHLIGHTS KCS_HIGHLIGHTS_SUBDIR KCS_PYTHON KCS_HIGHLIGHTS_PY KCS_KFXLIB_PATH KCS_CACHE_DIR"

FORCE=0
NOW=0
MODE=sync
for arg in "$@"; do
  case "$arg" in
    --now|--run-now) NOW=1 ;;
    --force) FORCE=1; NOW=1 ;;
    --setup-notify) MODE=setup-notify ;;
    --test-notify) MODE=test-notify ;;
    --version) echo "kindle-clippings-sync $VERSION"; exit 0 ;;
    -h|--help) sed -n '2,65p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opcao desconhecida: $arg" >&2; exit 2 ;;
  esac
done

# --- configuracao ----------------------------------------------------------
# Guarda o que veio do ambiente para ter prioridade sobre o arquivo.
for v in $CONFIG_VARS; do
  eval "__env_$v=\"\${$v-}\""
done

KCS_CONFIG="${KCS_CONFIG:-$HOME/.config/kindle-clippings-sync/config.env}"
if [ -f "$KCS_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$KCS_CONFIG"
fi

for v in $CONFIG_VARS; do
  eval "__val=\"\${__env_$v}\""
  # shellcheck disable=SC2154
  if [ -n "$__val" ]; then eval "$v=\"\$__val\""; fi
done

KCS_VAULT="${KCS_VAULT:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents}"
KCS_DEST_SUBDIR="${KCS_DEST_SUBDIR:-05 Conhecimento/Leituras/_Kindle}"
KCS_DEST="${KCS_DEST:-}"
KCS_SOURCE="${KCS_SOURCE:-auto}"
KCS_LOG="${KCS_LOG:-$HOME/Library/Logs/kindle-clippings-sync.log}"
KCS_STATE_DIR="${KCS_STATE_DIR:-$HOME/Library/Application Support/kindle-clippings-sync}"
KCS_NOTIFY="${KCS_NOTIFY:-1}"
KCS_NOTIFY_URL="${KCS_NOTIFY_URL:-}"
KCS_NOTIFY_KEY="${KCS_NOTIFY_KEY:-}"
KCS_NOTIFY_KEY_HEADER="${KCS_NOTIFY_KEY_HEADER:-Authorization}"
KCS_MAX_BACKUPS="${KCS_MAX_BACKUPS:-0}"
KCS_USB_VENDOR_ID="${KCS_USB_VENDOR_ID:-6473}"
KCS_MTP_PULL="${KCS_MTP_PULL:-}"
KCS_MTP_PULL_ARGS="${KCS_MTP_PULL_ARGS:-}"
KCS_MTP_BIN_DIR="${KCS_MTP_BIN_DIR:-}"
KCS_MTP_DELAY="${KCS_MTP_DELAY:-3}"
KCS_MTP_RETRIES="${KCS_MTP_RETRIES:-4}"
KCS_MTP_RETRY_INTERVAL="${KCS_MTP_RETRY_INTERVAL:-10}"
KCS_MTP_TIMEOUT="${KCS_MTP_TIMEOUT:-180}"
KCS_MTP_RESYNC_SECONDS="${KCS_MTP_RESYNC_SECONDS:-0}"
KCS_MTP_KILL_PTPCAMERAD="${KCS_MTP_KILL_PTPCAMERAD:-0}"
KCS_VOLUMES_ROOT="${KCS_VOLUMES_ROOT:-/Volumes}"
KCS_MOUNT_DELAY="${KCS_MOUNT_DELAY:-5}"
KCS_RETRIES="${KCS_RETRIES:-3}"
KCS_RETRY_INTERVAL="${KCS_RETRY_INTERVAL:-5}"
KCS_MOUNT_WINDOW="${KCS_MOUNT_WINDOW:-90}"
KCS_REQUIRE_MARKER="${KCS_REQUIRE_MARKER:-1}"
KCS_LIBEXEC="$HOME/.local/libexec/kindle-clippings-sync"
KCS_HIGHLIGHTS="${KCS_HIGHLIGHTS:-auto}"
KCS_HIGHLIGHTS_SUBDIR="${KCS_HIGHLIGHTS_SUBDIR:-Destaques}"
KCS_PYTHON="${KCS_PYTHON:-$KCS_LIBEXEC/venv/bin/python}"
KCS_HIGHLIGHTS_PY="${KCS_HIGHLIGHTS_PY:-$KCS_LIBEXEC/kcs_highlights.py}"
KCS_KFXLIB_PATH="${KCS_KFXLIB_PATH:-$KCS_LIBEXEC/kfxlib}"
KCS_CACHE_DIR="${KCS_CACHE_DIR:-$HOME/Library/Caches/kindle-clippings-sync}"

if [ "$NOW" = 1 ]; then
  KCS_MOUNT_DELAY=0
  KCS_MTP_DELAY=0
  KCS_RETRIES=1
fi

LOCK="$KCS_STATE_DIR/lock"
WORK=""
HL=0
HL_DEV=""
HL_TREE=""
HL_SELECT=""
HL_DB_PATTERN=""
HAVE_LOCK=0
RUNNING_PIDS=""
# Resumo para o webhook do Grok Bot (preenchido so quando a sync fala com o Kindle).
NOTIFY_TALKED=0
NOTIFY_DEVICE=""
NOTIFY_STATUS="ok"
NOTIFY_ERROR=""
NOTIFY_CLIP_CHANGED=0
NOTIFY_CLIP_ENTRIES=0
NOTIFY_HL_SUMMARY=""

# shellcheck disable=SC2329 # chamada pelo trap
cleanup() {
  local p
  for p in $RUNNING_PIDS; do kill -KILL "$p" 2>/dev/null; done
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ "$HAVE_LOCK" = 1 ] && rm -rf "$LOCK"
  return 0
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# --- utilitarios -----------------------------------------------------------
log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$ts" "$$" "$*" >>"$KCS_LOG" 2>/dev/null
  if [ -t 1 ]; then printf '%s\n' "$*"; fi
}

rotate_log() {
  local size
  [ -f "$KCS_LOG" ] || return 0
  size="$(wc -c <"$KCS_LOG" 2>/dev/null | tr -d ' ')"
  if [ -n "$size" ] && [ "$size" -gt 1048576 ]; then
    mv -f "$KCS_LOG" "$KCS_LOG.1" 2>/dev/null
  fi
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

file_size() { wc -c <"$1" 2>/dev/null | tr -d ' '; }

mtime_of() {
  case "$(uname -s)" in
    Darwin|*BSD) stat -f %m "$1" 2>/dev/null ;;
    *) stat -c %Y "$1" 2>/dev/null ;;
  esac
}

# Escapa texto para uma string AppleScript entre aspas.
as_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

notify() {
  local msg="$1" title="${2:-Kindle}"
  [ "$KCS_NOTIFY" = 1 ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$(as_escape "$msg")\" with title \"$(as_escape "$title")\"" \
    >/dev/null 2>&1 || log "aviso: falha ao exibir notificação"
}

# Python para montar o JSON do webhook (stdlib). Prefere o do extrator; cai no python3 do PATH.
notify_python() {
  if [ -x "$KCS_PYTHON" ]; then echo "$KCS_PYTHON"; return 0; fi
  command -v python3 2>/dev/null || command -v python 2>/dev/null
}

# Grava/substitui so a linha KEY=... no config.env (chmod 600). Nunca imprime o valor.
config_set() {
  local key="$1" val="$2" tmp dir
  dir="$(dirname "$KCS_CONFIG")"
  mkdir -p "$dir" || return 1
  touch "$KCS_CONFIG" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/kcs-cfg.XXXXXX")" || return 1
  # Remove linhas antigas dessa chave (com ou sem export).
  grep -Ev "^[[:space:]]*(export[[:space:]]+)?${key}=" "$KCS_CONFIG" >"$tmp" 2>/dev/null || : >"$tmp"
  printf '%s=%s\n' "$key" "$(sq "$val")" >>"$tmp"
  mv -f "$tmp" "$KCS_CONFIG"
  chmod 600 "$KCS_CONFIG"
}

# Header HTTP da chave: Authorization -> "Bearer <chave>"; outro nome -> chave pura.
notify_auth_header() {
  local hdr="${KCS_NOTIFY_KEY_HEADER:-Authorization}"
  if [ "$hdr" = "Authorization" ] || [ "$hdr" = "authorization" ]; then
    printf '%s: Bearer %s' "$hdr" "$KCS_NOTIFY_KEY"
  else
    printf '%s: %s' "$hdr" "$KCS_NOTIFY_KEY"
  fi
}

# POST do JSON em $1 para KCS_NOTIFY_URL. Devolve o codigo HTTP em stdout; 000 se curl falhar.
# Nunca loga a chave. So o status HTTP vai ao log.
notify_post() {
  local payload="$1" code body curlbin hdr
  curlbin="$(command -v curl || true)"
  if [ -z "$curlbin" ]; then
    log "webhook: curl nao encontrado; notificacao nao enviada"
    echo 000
    return 1
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/kcs-wh-body.XXXXXX")" || { echo 000; return 1; }
  hdr="$(notify_auth_header)"
  # --retry 2: ate 3 tentativas em falha de rede. Timeout curto.
  code="$("$curlbin" -sS -o "$body" -w "%{http_code}" --connect-timeout 10 --max-time 10 --retry 2 \
    -X POST -H "Content-Type: application/json; charset=utf-8" -H "$hdr" \
    --data-binary @"$payload" "$KCS_NOTIFY_URL" 2>/dev/null)" || code=""
  rm -f "$body"
  case "$code" in *[!0-9]*|"") code=000 ;; esac
  printf '%s\n' "$code"
}

# Monta o payload completo e envia. Nunca falha a sync por causa do webhook.
webhook_notify() {
  local py payload code hl_json clip_changed ran_at
  [ "$NOTIFY_TALKED" = 1 ] || return 0
  [ -n "$KCS_NOTIFY_URL" ] || return 0
  py="$(notify_python)"
  if [ -z "$py" ]; then
    log "webhook: sem python para montar o JSON; notificacao nao enviada"
    return 0
  fi
  payload="$(mktemp "${TMPDIR:-/tmp}/kcs-wh.XXXXXX")" || return 0
  hl_json="${NOTIFY_HL_SUMMARY:-}"
  [ -n "$hl_json" ] && [ -f "$hl_json" ] || hl_json=""
  clip_changed=false
  [ "$NOTIFY_CLIP_CHANGED" = 1 ] && clip_changed=true
  # Offset fixo -03:00 (America/Sao_Paulo sem horario de verao desde 2019).
  ran_at="$(date '+%Y-%m-%dT%H:%M:%S')-03:00"
  if ! KCS_WH_RAN_AT="$ran_at" KCS_WH_DEVICE="$NOTIFY_DEVICE" KCS_WH_STATUS="$NOTIFY_STATUS" \
    KCS_WH_ERROR="$NOTIFY_ERROR" KCS_WH_CLIP_CHANGED="$clip_changed" \
    KCS_WH_CLIP_ENTRIES="$NOTIFY_CLIP_ENTRIES" KCS_WH_HL_JSON="$hl_json" \
    "$py" - "$payload" <<'PY'
import json, os, sys
out = sys.argv[1]
hl = {"books": [], "totals": {"books": 0, "annotations": 0, "new": 0, "changed": 0}, "new_highlights": []}
path = os.environ.get("KCS_WH_HL_JSON") or ""
if path and os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as f:
            hl = json.load(f)
    except (OSError, ValueError):
        pass
err = os.environ.get("KCS_WH_ERROR") or None
if err == "":
    err = None
payload = {
    "ran_at": os.environ.get("KCS_WH_RAN_AT") or "",
    "device": os.environ.get("KCS_WH_DEVICE") or "",
    "status": os.environ.get("KCS_WH_STATUS") or "ok",
    "error": err,
    "my_clippings": {
        "changed": (os.environ.get("KCS_WH_CLIP_CHANGED") == "true"),
        "entries": int(os.environ.get("KCS_WH_CLIP_ENTRIES") or 0),
    },
    "highlights": hl.get("books") or [],
    "totals": hl.get("totals") or {"books": 0, "annotations": 0, "new": 0, "changed": 0},
}
news = hl.get("new_highlights") or []
if news:
    payload["new_highlights"] = news
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
PY
  then
    log "webhook: falha ao montar o JSON; notificacao nao enviada"
    rm -f "$payload"
    return 0
  fi
  code="$(notify_post "$payload")"
  rm -f "$payload"
  if [ "$code" = 000 ]; then
    log "webhook: falha ao enviar (rede/curl); a sincronizacao segue"
  elif [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    log "webhook: HTTP $code"
  else
    log "webhook: HTTP $code (a sincronizacao segue)"
  fi
  return 0
}

# POST de teste (status=test). Usado por --setup-notify e --test-notify.
test_notify() {
  local py payload code
  if [ -z "$KCS_NOTIFY_URL" ]; then
    echo "KCS_NOTIFY_URL nao configurada. Rode: kindle-clippings-sync --setup-notify" >&2
    return 1
  fi
  if [ -z "$KCS_NOTIFY_KEY" ]; then
    echo "KCS_NOTIFY_KEY nao configurada. Rode: kindle-clippings-sync --setup-notify" >&2
    return 1
  fi
  py="$(notify_python)"
  [ -n "$py" ] || { echo "python3 nao encontrado" >&2; return 1; }
  payload="$(mktemp "${TMPDIR:-/tmp}/kcs-wh-test.XXXXXX")" || return 1
  "$py" - "$payload" <<'PY'
import json, sys, datetime
out = sys.argv[1]
now = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S") + "-03:00"
json.dump({
    "ran_at": now,
    "device": "teste",
    "status": "test",
    "error": None,
    "my_clippings": {"changed": False, "entries": 0},
    "highlights": [],
    "totals": {"books": 0, "annotations": 0, "new": 0, "changed": 0},
}, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY
  echo "Enviando POST de teste para o webhook..."
  code="$(notify_post "$payload")"
  rm -f "$payload"
  echo "HTTP $code"
  case "$code" in
    2??) return 0 ;;
    *) return 1 ;;
  esac
}

setup_notify() {
  local url key hdr
  echo "Configuracao do aviso no Grok Bot (webhook da rotina)."
  echo "A URL e a chave ficam so em $KCS_CONFIG (chmod 600); a chave nunca e impressa."
  printf "URL do webhook: "
  IFS= read -r url || true
  if [ -z "$url" ]; then
    echo "URL vazia; cancelado." >&2
    return 2
  fi
  printf "Chave (sender key, digitacao oculta): "
  IFS= read -rs key || true
  printf '\n'
  if [ -z "$key" ]; then
    echo "Chave vazia; cancelado." >&2
    return 2
  fi
  printf "Header da chave [%s]: " "${KCS_NOTIFY_KEY_HEADER:-Authorization}"
  IFS= read -r hdr || true
  [ -n "$hdr" ] || hdr="${KCS_NOTIFY_KEY_HEADER:-Authorization}"
  config_set KCS_NOTIFY_URL "$url" || return 1
  config_set KCS_NOTIFY_KEY "$key" || return 1
  config_set KCS_NOTIFY_KEY_HEADER "$hdr" || return 1
  KCS_NOTIFY_URL="$url"
  KCS_NOTIFY_KEY="$key"
  KCS_NOTIFY_KEY_HEADER="$hdr"
  echo "Salvo. Enviando POST de teste..."
  test_notify
}


# Roda um comando com limite de tempo (o macOS nao tem `timeout`).
# Nao depende de SIGTERM: se o processo herdou SIGTERM ignorado (o que acontecia
# via helper de IOKit), "kill" comum nao encerra o vigia nem o comando. Por isso o
# vigia e parado com STOP/KILL e o comando recebe KILL 2 s depois do TERM.
run_with_timeout() {
  local secs="$1" pid watcher rc
  shift
  "$@" &
  pid=$!
  (
    sleep "$secs"
    kill -TERM "$pid" 2>/dev/null
    sleep 2
    kill -KILL "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  watcher=$!
  RUNNING_PIDS="$pid $watcher"
  wait "$pid"
  rc=$?
  kill -STOP "$watcher" 2>/dev/null
  pkill -KILL -P "$watcher" 2>/dev/null
  kill -KILL "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  RUNNING_PIDS=""
  return "$rc"
}

acquire_lock() {
  local other
  mkdir -p "$KCS_STATE_DIR" 2>/dev/null || { log "erro: não consegui criar $KCS_STATE_DIR"; exit 1; }
  if ! mkdir "$LOCK" 2>/dev/null; then
    other="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
      log "outra execução em andamento (pid $other); saindo"
      exit 0
    fi
    log "lock obsoleto removido (pid ${other:-?})"
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || { log "não consegui obter o lock; saindo"; exit 0; }
  fi
  HAVE_LOCK=1
  echo "$$" >"$LOCK/pid"
}

count_entries() {
  local n
  n="$(tr -d '\r' <"$1" | grep -c '^==========$')"
  printf '%s\n' "${n:-0}"
}

# Caminho de backup unico: "My Clippings YYYY-MM-DD HHMMSS.txt" (+ " (2)" se repetir).
backup_path() {
  local dir="$1" stamp="$2" p i=2
  p="$dir/My Clippings $stamp.txt"
  while [ -e "$p" ]; do
    p="$dir/My Clippings $stamp ($i).txt"
    i=$((i + 1))
  done
  printf '%s\n' "$p"
}

prune_backups() {
  local dir="$1" max="$2" total extra f
  [ "$max" -gt 0 ] 2>/dev/null || return 0
  total="$(find "$dir" -maxdepth 1 -type f -name 'My Clippings *.txt' | wc -l | tr -d ' ')"
  extra=$((total - max))
  [ "$extra" -gt 0 ] || return 0
  find "$dir" -maxdepth 1 -type f -name 'My Clippings *.txt' | LC_ALL=C sort | head -n "$extra" |
    while IFS= read -r f; do rm -f "$f" && log "backup antigo removido: $(basename "$f")"; done
}

write_note() {
  local note="$1" entries="$2" src="$3" hash="$4" backups="$5" iso="$6" human_date="$7" human_time="$8"
  local tmp="$note.tmp.$$"
  local label="entradas"
  [ "$entries" = 1 ] && label="entrada"
  cat >"$tmp" <<NOTE
---
tags:
  - kindle
  - leituras
  - kindle-sync
ultima_sincronizacao: $iso
entradas: $entries
origem: "$src"
sha256: $hash
backups: $backups
---

# Kindle Sync

Nota gerada automaticamente pelo kindle-clippings-sync. Ela é reescrita a cada sincronização, então não vale a pena editá-la à mão.

- Última sincronização: $human_date às $human_time
- Total: $entries $label (contagem pelos separadores \`==========\`)
- Arquivo copiado: [[My Clippings.txt]]
- Origem no Kindle: \`$src\`
- Backups guardados em \`backups/\`: $backups

## Como funciona

Sempre que o Kindle é conectado ao Mac via USB, o launchd executa o script. Se o conteúdo de \`My Clippings.txt\` mudou desde a última sincronização (comparação por SHA-256), o arquivo é copiado para esta pasta e uma cópia datada vai para \`backups/\`. O assistente de leitura usa esse arquivo para gerar as notas de capítulo de cada livro.
NOTE
  mv -f "$tmp" "$note"
}

# Pasta de destino no cofre (vazio se o cofre nao existe).
dest_dir() {
  if [ -n "$KCS_DEST" ]; then
    printf '%s\n' "$KCS_DEST"
  elif [ -d "$KCS_VAULT" ]; then
    printf '%s\n' "$KCS_VAULT/$KCS_DEST_SUBDIR"
  fi
}

# Sincroniza um arquivo local (do volume ou baixado via MTP) com o cofre.
# Requer o lock. Retorna 0 em sucesso ou "sem alteracoes".
sync_file() {
  local src="$1" origin="$2"
  local dest dest_file backup_dir note_file state_hash src_hash last_hash tmp ok stamp backup entries nbackups

  if [ -n "$KCS_DEST" ]; then
    dest="$KCS_DEST"
  else
    if [ ! -d "$KCS_VAULT" ]; then
      log "erro: cofre do Obsidian não encontrado: $KCS_VAULT"
      notify "Cofre do Obsidian não encontrado. Veja o log." "Kindle: erro"
      return 1
    fi
    dest="$KCS_VAULT/$KCS_DEST_SUBDIR"
  fi
  dest_file="$dest/$CLIPPINGS_NAME"
  backup_dir="$dest/backups"
  note_file="$dest/Kindle Sync.md"
  state_hash="$KCS_STATE_DIR/last.sha256"

  src_hash="$(sha256_of "$src")"
  if [ -z "$src_hash" ]; then
    log "erro: não consegui ler $src"
    return 1
  fi

  last_hash="$(cat "$state_hash" 2>/dev/null)"
  if [ "$FORCE" != 1 ] && [ "$src_hash" = "$last_hash" ] && [ -f "$dest_file" ] &&
    [ "$(sha256_of "$dest_file")" = "$src_hash" ]; then
    # Loga "sem alteracoes" uma vez por conteudo, para nao encher o log.
    if [ "$(cat "$KCS_STATE_DIR/unchanged.logged" 2>/dev/null)" != "$src_hash" ] || [ -t 1 ]; then
      log "sem alterações ($origin, sha256 ${src_hash:0:12})"
      printf '%s\n' "$src_hash" >"$KCS_STATE_DIR/unchanged.logged"
    fi
    NOTIFY_CLIP_CHANGED=0
    NOTIFY_CLIP_ENTRIES="$(count_entries "$dest_file")"
    return 0
  fi

  if ! mkdir -p "$backup_dir" 2>/dev/null; then
    log "erro: não consegui criar $backup_dir (permissão do iCloud Drive? veja o README)"
    notify "Erro ao gravar no cofre. Veja o log." "Kindle: erro"
    return 1
  fi

  # Copia para um temporario no destino, confere o hash e troca atomicamente.
  tmp="$dest/.My Clippings.txt.tmp.$$"
  ok=0
  for _ in 1 2 3; do
    if cp "$src" "$tmp" 2>>"$KCS_LOG" && [ "$(sha256_of "$tmp")" = "$src_hash" ]; then
      ok=1
      break
    fi
    sleep 1
    src_hash="$(sha256_of "$src")"
  done
  if [ "$ok" != 1 ]; then
    rm -f "$tmp"
    log "erro: falha ao copiar $origin para $dest (permissão? veja o README)"
    notify "Erro ao copiar os destaques. Veja o log." "Kindle: erro"
    return 1
  fi
  mv -f "$tmp" "$dest_file"

  stamp="$(date '+%Y-%m-%d %H%M%S')"
  backup="$(backup_path "$backup_dir" "$stamp")"
  cp "$dest_file" "$backup" || log "aviso: falha ao criar backup $backup"
  prune_backups "$backup_dir" "$KCS_MAX_BACKUPS"

  entries="$(count_entries "$dest_file")"
  nbackups="$(find "$backup_dir" -maxdepth 1 -type f -name 'My Clippings *.txt' | wc -l | tr -d ' ')"
  write_note "$note_file" "$entries" "$origin" "$src_hash" "$nbackups" \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$(date '+%d/%m/%Y')" "$(date '+%H:%M:%S')"

  printf '%s\n' "$src_hash" >"$state_hash"
  rm -f "$KCS_STATE_DIR/unchanged.logged"

  log "sincronizado: $entries entradas de $origin para $dest_file (backup: $(basename "$backup"))"
  NOTIFY_CLIP_CHANGED=1
  NOTIFY_CLIP_ENTRIES="$entries"
  if [ "$entries" = 1 ]; then
    notify "Kindle sincronizado: 1 destaque" "Kindle"
  else
    notify "Kindle sincronizado: $entries destaques" "Kindle"
  fi
  return 0
}

# --- MTP --------------------------------------------------------------------
find_ioreg() {
  if command -v ioreg >/dev/null 2>&1; then command -v ioreg; return 0; fi
  [ -x /usr/sbin/ioreg ] && { echo /usr/sbin/ioreg; return 0; }
  return 1
}

# Lista Kindles no plano IOUSB: "vendor<TAB>product<TAB>chave<TAB>nome".
# A chave e o sessionID (muda a cada conexao) ou, na falta dele, o locationID.
usb_kindles() {
  local ioreg
  ioreg="$(find_ioreg)" || return 1
  "$ioreg" -p IOUSB -l -w0 2>/dev/null | awk -v vid="$KCS_USB_VENDOR_ID" '
    function val(s, key) { sub(".*\"" key "\" = ", "", s); gsub(/^"|"$/, "", s); return s }
    function flush() {
      if (node != "" && cls ~ /^IOUSB(Host)?Device$/ &&
          (vendor == vid || tolower(node " " pname " " vname) ~ /kindle/)) {
        key = (sess != "") ? sess : vendor ":" product ":" loc
        print vendor "\t" product "\t" key "\t" ((pname != "") ? pname : node)
      }
      node = ""; cls = ""; vendor = ""; product = ""; sess = ""; loc = ""; pname = ""; vname = ""
    }
    /\+-o / {
      flush()
      line = $0; sub(/^.*\+-o /, "", line)
      p = index(line, "  <class ")
      if (p == 0) next
      node = substr(line, 1, p - 1); sub(/@[0-9a-fA-F]+$/, "", node)
      cls = substr(line, p + 9); sub(/,.*/, "", cls); sub(/>.*/, "", cls)
      next
    }
    /"idVendor" = /          { vendor = val($0, "idVendor") + 0; next }
    /"idProduct" = /         { product = val($0, "idProduct") + 0; next }
    /"sessionID" = /         { sess = val($0, "sessionID"); next }
    /"locationID" = /        { loc = val($0, "locationID"); next }
    /"USB Product Name" = /  { pname = val($0, "USB Product Name"); next }
    /"USB Vendor Name" = /   { vname = val($0, "USB Vendor Name"); next }
    END { flush() }'
}

find_mtp_tool() {
  local name="$1" d
  if [ -n "$KCS_MTP_BIN_DIR" ]; then
    [ -x "$KCS_MTP_BIN_DIR/$name" ] && { echo "$KCS_MTP_BIN_DIR/$name"; return 0; }
    return 1
  fi
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
  for d in /opt/homebrew/bin /usr/local/bin; do
    [ -x "$d/$name" ] && { echo "$d/$name"; return 0; }
  done
  return 1
}

# A saida de um comando mtp-* indica aparelho ocupado/indisponivel?
mtp_busy() {
  grep -Eqi 'busy|claim_interface|Unable to open raw device|PANIC|error connecting|No Devices have been found|no devices found|No raw devices found|^No devices\.|Error getting file' "$1"
}

# Processos que costumam segurar o Kindle via MTP. Usa o caminho completo do
# executavel (ps comm), porque o pgrep do macOS so ve 16 caracteres do nome.
mtp_holders() {
  local p found="" list
  list="$(ps -axo comm= 2>/dev/null)"
  [ -n "$list" ] || return 0
  for p in "Android File Transfer" "Android File Transfer Agent" "OpenMTP" "MacDroid" \
    "Kindle" "Send to Kindle" "Image Capture" "Photos" "ptpcamerad"; do
    if printf '%s\n' "$list" | grep -q -e "/$p\$" -e "^$p\$"; then found="${found:+$found, }$p"; fi
  done
  printf '%s\n' "$found"
}

# Baixa My Clippings.txt via MTP para "$1".
# Retorno: 0 ok, 2 ocupado/indisponivel, 3 arquivo nao existe no aparelho, 1 outro erro.
mtp_pull() {
  if [ -n "$MTP_PULL" ]; then
    mtp_pull_single "$1"
  else
    mtp_pull_tools "$1"
  fi
}

# Caminho preferido: kcs-mtp-pull, uma unica sessao do libmtp e sem reset USB
# ao fechar (o reset derrubava o Kindle Paperwhite do USB).
mtp_pull_single() {
  local out="$1" txt="$WORK/mtp-pull.txt" rc
  rm -f "$out"
  # KCS_MTP_PULL_ARGS pode ter varias opcoes (sem aspas de proposito)
  if [ "$HL" = 1 ]; then
    rm -rf "$HL_DEV" "$HL_TREE"
    # shellcheck disable=SC2086
    run_with_timeout "$KCS_MTP_TIMEOUT" "$MTP_PULL" $KCS_MTP_PULL_ARGS "$out" --list-to "$HL_TREE" \
      --get-match "$HL_DB_PATTERN" "$HL_DEV" --then "$HL_SELECT" >"$txt" 2>&1 </dev/null
  else
    # shellcheck disable=SC2086
    run_with_timeout "$KCS_MTP_TIMEOUT" "$MTP_PULL" $KCS_MTP_PULL_ARGS "$out" >"$txt" 2>&1 </dev/null
  fi
  rc=$?
  if [ "$rc" -gt 128 ]; then log "kcs-mtp-pull excedeu ${KCS_MTP_TIMEOUT}s"; return 2; fi
  case "$rc" in
    0)
      if [ ! -f "$out" ]; then
        log "kcs-mtp-pull terminou sem gerar o arquivo: $(tr '\n' ' ' <"$txt" | cut -c1-300)"
        return 1
      fi
      log "baixado via MTP numa sessão: $(grep '^OK ' "$txt" | sed 's/^OK \([0-9]*\) \([0-9]*\) /item \1, \2 bytes, /') [$(grep 'flags usados' "$txt" | sed 's/.*flags usados //')]"
      if [ "$HL" = 1 ]; then
        log "destaques: $(grep -c '^GOT ' "$txt") arquivo(s) extra(s) na mesma sessão ($(grep -c '^GOT .*ksdk_annotation_v1.db' "$txt") banco(s), $(grep -c '^GOT .*\.kfx\.new$' "$txt") livro(s))"
        grep -E '^(ERR|kcs_highlights:)' "$txt" | head -n 5 | while IFS= read -r l; do log "destaques: $l"; done
      fi
      return 0
      ;;
    2|3) return "$rc" ;;
    *)
      mtp_busy "$txt" && return 2
      log "kcs-mtp-pull falhou (código $rc): $(tr '\n' ' ' <"$txt" | cut -c1-300)"
      return 1
      ;;
  esac
}

# Reserva: ferramentas de linha de comando do libmtp (tres sessoes).
mtp_pull_tools() {
  local out="$1" files_txt="$WORK/mtp-files.txt" folders_txt="$WORK/mtp-folders.txt"
  local get_txt="$WORK/mtp-getfile.txt" docs cands chosen id size got rc

  run_with_timeout "$KCS_MTP_TIMEOUT" "$MTP_FILES" >"$files_txt" 2>&1 </dev/null
  rc=$?
  if [ "$rc" -gt 128 ]; then log "mtp-files excedeu ${KCS_MTP_TIMEOUT}s"; return 2; fi
  # Avisos do libusb podem aparecer mesmo com sucesso: so e "ocupado" se nada foi listado.
  if ! grep -q '^File ID: ' "$files_txt" && mtp_busy "$files_txt"; then return 2; fi

  # Arquivos chamados My Clippings.txt: "id<TAB>parent<TAB>tamanho".
  cands="$(awk -v want="$(printf '%s' "$CLIPPINGS_NAME" | tr '[:upper:]' '[:lower:]')" '
    function emit() { if (id != "" && tolower(name) == want) print id "\t" parent "\t" size }
    /^File ID: /           { emit(); id = $3; name = ""; parent = ""; size = ""; next }
    /^[ \t]*Filename: /    { s = $0; sub(/^[ \t]*Filename: /, "", s); sub(/\r$/, "", s); name = s; next }
    /^[ \t]*File size /    { size = $3; next }
    /^[ \t]*Parent ID: /   { parent = $3; next }
    END { emit() }' "$files_txt")"
  if [ -z "$cands" ]; then
    if grep -q '^File ID: ' "$files_txt"; then return 3; fi
    log "mtp-files não listou nenhum arquivo"
    return 2
  fi

  # Pastas "documents": "id<TAB>nivel" (nivel 0 = raiz do armazenamento).
  docs=""
  if [ -n "$MTP_FOLDERS" ]; then
    run_with_timeout "$KCS_MTP_TIMEOUT" "$MTP_FOLDERS" >"$folders_txt" 2>&1 </dev/null
    rc=$?
    if [ "$rc" -gt 128 ]; then log "mtp-folders excedeu ${KCS_MTP_TIMEOUT}s"; return 2; fi
    if ! grep -Eq '^[0-9]+	' "$folders_txt" && mtp_busy "$folders_txt"; then return 2; fi
    docs="$(awk -F'\t' '/^[0-9]+\t/ {
        n = $2; sub(/\r$/, "", n); m = match(n, /[^ ]/); lvl = (m > 0) ? int((m - 1) / 2) : 0
        sub(/^ +/, "", n); if (tolower(n) == "documents") print $1 "\t" lvl }' "$folders_txt")"
  fi

  # Preferencia: pai = documents na raiz; depois qualquer documents; depois o primeiro.
  chosen="$(printf '%s\n' "$cands" | KCS_DOCS="$docs" awk -F'\t' '
    BEGIN { n = split(ENVIRON["KCS_DOCS"], d, "\n"); for (i = 1; i <= n; i++) { split(d[i], f, "\t"); if (f[1] != "") lvl[f[1]] = f[2] } }
    { if ($2 in lvl) { score = (lvl[$2] == 0) ? 3 : 2 } else { score = 1 }
      if (score > best) { best = score; line = $0 } }
    END { print line }')"
  id="$(printf '%s' "$chosen" | cut -f1)"
  size="$(printf '%s' "$chosen" | cut -f3)"
  [ "$(printf '%s\n' "$cands" | wc -l | tr -d ' ')" -gt 1 ] &&
    log "vários $CLIPPINGS_NAME no Kindle; usando o item $id (pasta documents preferida)"
  if [ -z "$docs" ] || ! printf '%s\n' "$docs" | cut -f1 | grep -qx "$(printf '%s' "$chosen" | cut -f2)"; then
    log "aviso: não confirmei a pasta documents; usando o item $id"
  fi

  rm -f "$out"
  run_with_timeout "$KCS_MTP_TIMEOUT" "$MTP_GETFILE" "$id" "$out" >"$get_txt" 2>&1 </dev/null
  rc=$?
  if [ "$rc" -gt 128 ]; then log "mtp-getfile excedeu ${KCS_MTP_TIMEOUT}s"; return 2; fi
  if [ "$rc" -ne 0 ] || [ ! -f "$out" ]; then
    mtp_busy "$get_txt" && return 2
    log "mtp-getfile falhou (código $rc): $(tr '\n' ' ' <"$get_txt" | cut -c1-300)"
    return 1
  fi
  got="$(file_size "$out")"
  if [ -n "$size" ] && [ "$got" != "$size" ]; then
    log "download incompleto: $got de $size bytes"
    return 1
  fi
  return 0
}

# Aspas simples para gerar um script sh seguro.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Liga a coleta de destaques (banco de anotacoes + livros) na mesma sessao MTP?
highlights_setup() {
  HL=0
  case "$KCS_HIGHLIGHTS" in
    0|no|off) return 0 ;;
  esac
  if [ -z "$MTP_PULL" ] || [ ! -x "$KCS_PYTHON" ] || [ ! -f "$KCS_HIGHLIGHTS_PY" ]; then
    [ "$KCS_HIGHLIGHTS" = 1 ] && log "aviso: destaques ligados, mas falta o kcs-mtp-pull, o python ($KCS_PYTHON) ou o extrator ($KCS_HIGHLIGHTS_PY); rode ./install.sh"
    return 0
  fi
  HL_DEV="$WORK/device"
  HL_TREE="$WORK/tree.tsv"
  HL_SELECT="$WORK/kcs-select"
  HL_DB_PATTERN='/system/ksdk/.annotations/amzn1.account.*/ksdk_annotation_v1.db'
  mkdir -p "$KCS_CACHE_DIR/books" || return 0
  {
    echo '#!/bin/sh'
    printf 'exec %s %s select --db-dir %s --cache %s\n' "$(sq "$KCS_PYTHON")" "$(sq "$KCS_HIGHLIGHTS_PY")" \
      "$(sq "$HL_DEV")" "$(sq "$KCS_CACHE_DIR")"
  } >"$HL_SELECT" && chmod +x "$HL_SELECT" && HL=1
}

# Depois da sessao: texto dos destaques e uma nota por livro no cofre.
highlights_render() {
  local name="$1" dest out rc line nb total new written nbk
  [ "$HL" = 1 ] || return 0
  dest="$(dest_dir)"
  [ -n "$dest" ] || return 0
  if [ ! -d "$HL_DEV" ]; then
    log "destaques: nenhum banco de anotações veio do $name"
    return 0
  fi
  out="$WORK/render.txt"
  NOTIFY_HL_SUMMARY="$WORK/highlights-summary.json"
  note_rel="$KCS_DEST_SUBDIR/$KCS_HIGHLIGHTS_SUBDIR"
  [ -n "$KCS_DEST" ] && note_rel="$(basename "$KCS_DEST")/$KCS_HIGHLIGHTS_SUBDIR"
  run_with_timeout "${KCS_HIGHLIGHTS_TIMEOUT:-300}" "$KCS_PYTHON" "$KCS_HIGHLIGHTS_PY" render --tree "$HL_TREE" \
    --db-dir "$HL_DEV" --cache "$KCS_CACHE_DIR" --out "$dest/$KCS_HIGHLIGHTS_SUBDIR" --backups "$dest/backups" \
    --state "$KCS_STATE_DIR" --kfxlib "$KCS_KFXLIB_PATH" --origin "MTP ($name): ksdk_annotation_v1.db" \
    --max-backups "$KCS_MAX_BACKUPS" --summary "$NOTIFY_HL_SUMMARY" --note-rel "$note_rel" \
    >"$out" 2>&1 </dev/null
  rc=$?
  line="$(grep '^DESTAQUES ' "$out" | tail -n 1)"
  if [ "$rc" -ne 0 ] || [ -z "$line" ]; then
    log "aviso: extração de destaques falhou (código $rc): $(grep -v '^DESTAQUES ' "$out" | tail -n 3 | tr '\n' ' ' | cut -c1-300)"
    return 0
  fi
  grep '^kcs_highlights: ' "$out" | while IFS= read -r l; do log "destaques: ${l#kcs_highlights: }"; done
  # shellcheck disable=SC2086
  set -- $line
  nb="$2"; total="$3"; new="$4"; written="$5"; nbk="${6:-0}"
  log "destaques: $nb livro(s), $total anotações ($new novas), $written nota(s) atualizada(s) em $dest/$KCS_HIGHLIGHTS_SUBDIR${nbk:+, $nbk backup(s) do banco}"
  if [ "${new:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$new" = 1 ]; then notify "Kindle: 1 destaque novo" "Kindle"; else notify "Kindle: $new destaques novos" "Kindle"; fi
  fi
  return 0
}

# Esta conexao USB ja foi sincronizada (e nao e hora de reler)?
session_done() {
  local key="$1" now last_key last_time
  [ "$NOW" != 1 ] || return 1
  [ -f "$KCS_STATE_DIR/mtp-session" ] || return 1
  now="$(date +%s)"
  last_key="$(cut -f1 <"$KCS_STATE_DIR/mtp-session")"
  last_time="$(cut -f2 <"$KCS_STATE_DIR/mtp-session")"
  [ "$last_key" = "$key" ] || return 1
  if [ "$KCS_MTP_RESYNC_SECONDS" -le 0 ] 2>/dev/null; then return 0; fi
  [ $((now - ${last_time:-0})) -lt "$KCS_MTP_RESYNC_SECONDS" ]
}

find_mtp_pull() {
  local def="$HOME/.local/libexec/kindle-clippings-sync/kcs-mtp-pull"
  case "$KCS_MTP_PULL" in
    none) return 1 ;;
    '') ;;
    *) [ -x "$KCS_MTP_PULL" ] && { echo "$KCS_MTP_PULL"; return 0; }; return 1 ;;
  esac
  [ -x "$def" ] && { echo "$def"; return 0; }
  find_mtp_tool kcs-mtp-pull
}

run_mtp() {
  local info key name session_file now rc attempt holders tmpfile

  info="$(usb_kindles | head -n 1)"
  [ -n "$info" ] || return 10 # nenhum Kindle no USB
  key="$(printf '%s' "$info" | cut -f3)"
  name="$(printf '%s' "$info" | cut -f4)"
  session_file="$KCS_STATE_DIR/mtp-session"
  now="$(date +%s)"

  # Ja sincronizado nesta conexao? Sai sem abrir o MTP (barato para o StartInterval
  # e para disparos repetidos do evento de IOKit).
  session_done "$key" && return 0

  # So uma sincronizacao por vez; quem chegar depois sai sem abrir o MTP.
  acquire_lock
  # Outra execucao pode ter terminado esta mesma conexao enquanto esperavamos.
  session_done "$key" && return 0

  NOTIFY_TALKED=1
  NOTIFY_DEVICE="$name"
  NOTIFY_STATUS="ok"
  NOTIFY_ERROR=""

  # Ja falhou nesta conexao (aparelho ocupado)? Nas rodadas automaticas seguintes
  # tenta so uma vez, para nao segurar o job nem encher o log.
  if [ "$NOW" != 1 ] && [ "$(cat "$KCS_STATE_DIR/mtp-failed" 2>/dev/null)" = "$key" ]; then
    KCS_MTP_RETRIES=1
  fi

  MTP_PULL="$(find_mtp_pull)"
  MTP_FILES="$(find_mtp_tool mtp-files)"
  MTP_GETFILE="$(find_mtp_tool mtp-getfile)"
  MTP_FOLDERS="$(find_mtp_tool mtp-folders)"
  if [ -z "$MTP_PULL" ] && { [ -z "$MTP_FILES" ] || [ -z "$MTP_GETFILE" ]; }; then
    log "erro: $name conectado via MTP, mas o libmtp não foi encontrado (procurei no PATH, /opt/homebrew/bin e /usr/local/bin). Rode: brew install libmtp"
    if [ "$(cat "$KCS_STATE_DIR/mtp-notified" 2>/dev/null)" != "$key" ]; then
      notify "Instale o libmtp: brew install libmtp" "Kindle: erro"
      printf '%s\n' "$key" >"$KCS_STATE_DIR/mtp-notified"
    fi
    NOTIFY_STATUS="error"
    NOTIFY_ERROR="libmtp não encontrado"
    webhook_notify
    return 1
  fi
  if [ -z "$MTP_PULL" ]; then
    log "aviso: kcs-mtp-pull não encontrado (rode ./install.sh); usando mtp-files/mtp-folders/mtp-getfile, que abrem 3 sessões e podem derrubar o Kindle do USB"
    [ -z "$MTP_FOLDERS" ] && log "aviso: mtp-folders não encontrado; não dá para confirmar a pasta documents"
  fi

  [ "$KCS_MTP_DELAY" -gt 0 ] 2>/dev/null && sleep "$KCS_MTP_DELAY"

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/kcs-mtp.XXXXXX")" || { log "erro: mktemp falhou"; return 1; }
  tmpfile="$WORK/$CLIPPINGS_NAME"
  highlights_setup
  if [ "$HL" = 1 ]; then
    log "$name detectado via USB/MTP; baixando $CLIPPINGS_REL e o banco de anotações"
  else
    log "$name detectado via USB/MTP; baixando $CLIPPINGS_REL"
  fi

  attempt=1
  while :; do
    mtp_pull "$tmpfile"
    rc=$?
    [ "$rc" -eq 0 ] && break
    if [ "$rc" -eq 3 ]; then
      log "$CLIPPINGS_NAME não existe no $name (nenhum destaque ainda?)"
      highlights_render "$name"
      printf '%s\t%s\n' "$key" "$now" >"$session_file"
      webhook_notify
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      holders="$(mtp_holders)"
      log "Kindle ocupado ou indisponível via MTP (tentativa $attempt/$KCS_MTP_RETRIES). Outro app pode estar usando o aparelho${holders:+: $holders}. Saída: $(cat "$WORK"/mtp-*.txt 2>/dev/null | grep -Ei 'busy|claim|PANIC|Unable|error|No dev|No raw' | head -n 3 | tr '\n' ' ')"
      if [ "$KCS_MTP_KILL_PTPCAMERAD" = 1 ] && command -v killall >/dev/null 2>&1; then
        killall ptpcamerad >/dev/null 2>&1 && log "ptpcamerad encerrado para liberar o MTP"
      fi
    fi
    [ "$attempt" -ge "$KCS_MTP_RETRIES" ] && break
    attempt=$((attempt + 1))
    sleep "$KCS_MTP_RETRY_INTERVAL"
  done

  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$key" >"$KCS_STATE_DIR/mtp-failed"
    log "erro: não consegui baixar $CLIPPINGS_REL via MTP após $KCS_MTP_RETRIES tentativas. Feche Android File Transfer, OpenMTP, o app Kindle ou a Captura de Imagem e reconecte (ou rode: kindle-clippings-sync --now)"
    if [ "$(cat "$KCS_STATE_DIR/mtp-notified" 2>/dev/null)" != "$key" ]; then
      notify "Kindle ocupado por outro app. Feche o Android File Transfer e reconecte." "Kindle: erro"
      printf '%s\n' "$key" >"$KCS_STATE_DIR/mtp-notified"
    fi
    NOTIFY_STATUS="error"
    NOTIFY_ERROR="falha ao baixar via MTP após $KCS_MTP_RETRIES tentativas"
    webhook_notify
    return 1
  fi

  # Diagnostico: o Kindle continua no USB depois de fechar a sessao?
  if [ -n "$MTP_PULL" ]; then
    sleep "${KCS_MTP_POSTCHECK_DELAY:-2}"
    if usb_kindles | grep -q .; then
      log "$name continua no USB depois da sessão MTP"
    else
      log "aviso: $name saiu do USB depois da sessão MTP (tente KCS_MTP_PULL_ARGS=--no-release-interface)"
    fi
  fi

  sync_file "$tmpfile" "MTP ($name): $CLIPPINGS_REL"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    highlights_render "$name"
    printf '%s\t%s\n' "$key" "$now" >"$session_file"
    rm -f "$KCS_STATE_DIR/mtp-failed"
  else
    NOTIFY_STATUS="error"
    NOTIFY_ERROR="falha ao gravar no cofre"
  fi
  webhook_notify
  return "$rc"
}

# --- /Volumes ---------------------------------------------------------------
# Um volume parece um Kindle? Tolerante: basta um dos marcadores.
looks_like_kindle() {
  local vol="$1" name
  [ "$KCS_REQUIRE_MARKER" = 1 ] || return 0
  name="$(basename "$vol" | tr '[:upper:]' '[:lower:]')"
  case "$name" in *kindle*) return 0 ;; esac
  [ -d "$vol/system" ] && return 0
  [ -e "$vol/.kindle" ] && return 0
  [ -e "$vol/system/version.txt" ] && return 0
  [ -e "$vol/amazon-cover-bug" ] && return 0
  [ -d "$vol/.active_content_sandbox" ] && return 0
  return 1
}

find_clippings() {
  local f vol
  for f in "$KCS_VOLUMES_ROOT"/*/"$CLIPPINGS_REL"; do
    [ -f "$f" ] || continue
    vol="${f%/"$CLIPPINGS_REL"}"
    if looks_like_kindle "$vol"; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

run_volumes() {
  local src attempt mt now
  [ -d "$KCS_VOLUMES_ROOT" ] || return 0
  if ! ls "$KCS_VOLUMES_ROOT" >/dev/null 2>&1; then
    log "erro: sem permissão para listar $KCS_VOLUMES_ROOT (verifique Volumes Removíveis / Acesso Total ao Disco para /bin/bash)"
    return 1
  fi

  src="$(find_clippings)"
  if [ -z "$src" ]; then
    # So vale esperar se algo acabou de ser montado (disparo por StartOnMount).
    mt="$(mtime_of "$KCS_VOLUMES_ROOT")"
    now="$(date +%s)"
    if [ "$NOW" != 1 ] && [ -n "$mt" ] && [ $((now - mt)) -le "$KCS_MOUNT_WINDOW" ]; then
      [ "$KCS_MOUNT_DELAY" -gt 0 ] 2>/dev/null && sleep "$KCS_MOUNT_DELAY"
      attempt=1
      while :; do
        src="$(find_clippings)" && break
        src=""
        [ "$attempt" -ge "$KCS_RETRIES" ] && break
        attempt=$((attempt + 1))
        sleep "$KCS_RETRY_INTERVAL"
      done
    fi
  fi
  [ -n "$src" ] || return 0 # nenhum Kindle: sai em silencio

  acquire_lock
  NOTIFY_TALKED=1
  NOTIFY_DEVICE="$(basename "${src%"/$CLIPPINGS_REL"}")"
  NOTIFY_STATUS="ok"
  NOTIFY_ERROR=""
  sync_file "$src" "$src"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    NOTIFY_STATUS="error"
    NOTIFY_ERROR="falha ao gravar no cofre"
  fi
  webhook_notify
  return "$rc"
}

# --- execucao ---------------------------------------------------------------
case "$MODE" in
  setup-notify) setup_notify; exit $? ;;
  test-notify) test_notify; exit $? ;;
esac

mkdir -p "$(dirname "$KCS_LOG")" 2>/dev/null
rotate_log

case "$KCS_SOURCE" in
  auto|mtp)
    run_mtp
    rc=$?
    if [ "$rc" -ne 10 ]; then exit "$rc"; fi
    [ "$KCS_SOURCE" = mtp ] && exit 0
    ;;
  volumes) ;;
  *) log "erro: KCS_SOURCE inválido: $KCS_SOURCE (use auto, mtp ou volumes)"; exit 2 ;;
esac

run_volumes
exit $?
