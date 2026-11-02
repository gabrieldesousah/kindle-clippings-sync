#!/bin/bash
# kindle-clippings-sync: copia "documents/My Clippings.txt" do Kindle para o
# cofre do Obsidian sempre que o Kindle e montado no Mac.
#
# Compativel com o /bin/bash 3.2 do macOS. Usa apenas ferramentas do sistema
# (shasum, cp, mv, mkdir, osascript). Nada de Homebrew ou python3.
#
# Uso: kindle-clippings-sync.sh [--now] [--force] [--help]
#   --now    pula a espera inicial e as novas tentativas (execucao manual)
#   --force  copia mesmo que o conteudo nao tenha mudado
#
# Configuracao (arquivo de config ou variaveis de ambiente; o ambiente vence):
#   KCS_VAULT          caminho do cofre do Obsidian
#   KCS_DEST_SUBDIR    pasta dentro do cofre (padrao: 05 Conhecimento/Leituras/_Kindle)
#   KCS_DEST           caminho absoluto do destino (ignora KCS_VAULT/KCS_DEST_SUBDIR)
#   KCS_VOLUMES_ROOT   raiz dos volumes montados (padrao: /Volumes)
#   KCS_LOG            arquivo de log (padrao: ~/Library/Logs/kindle-clippings-sync.log)
#   KCS_STATE_DIR      estado interno: hash e lock
#   KCS_MOUNT_DELAY    segundos de espera antes de procurar (padrao: 5)
#   KCS_RETRIES        tentativas de encontrar o Kindle (padrao: 3)
#   KCS_RETRY_INTERVAL segundos entre tentativas (padrao: 5)
#   KCS_NOTIFY         1 para notificar via osascript, 0 para desligar (padrao: 1)
#   KCS_REQUIRE_MARKER 1 exige marcador de Kindle no volume, 0 aceita qualquer (padrao: 1)
#   KCS_MAX_BACKUPS    manter so os N backups mais recentes; 0 = manter todos (padrao: 0)
#   KCS_CONFIG         arquivo de config (padrao: ~/.config/kindle-clippings-sync/config.env)

set -u
umask 022

VERSION="1.0.0"
CLIPPINGS_REL="documents/My Clippings.txt"

CONFIG_VARS="KCS_VAULT KCS_DEST_SUBDIR KCS_DEST KCS_VOLUMES_ROOT KCS_LOG KCS_STATE_DIR \
KCS_MOUNT_DELAY KCS_RETRIES KCS_RETRY_INTERVAL KCS_NOTIFY KCS_REQUIRE_MARKER KCS_MAX_BACKUPS"

FORCE=0
NOW=0
for arg in "$@"; do
  case "$arg" in
    --now|--run-now) NOW=1 ;;
    --force) FORCE=1 ;;
    --version) echo "kindle-clippings-sync $VERSION"; exit 0 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opcao desconhecida: $arg" >&2; exit 2 ;;
  esac
done

# --- configuracao ----------------------------------------------------------
# Guarda o que veio do ambiente para que tenha prioridade sobre o arquivo.
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
KCS_VOLUMES_ROOT="${KCS_VOLUMES_ROOT:-/Volumes}"
KCS_LOG="${KCS_LOG:-$HOME/Library/Logs/kindle-clippings-sync.log}"
KCS_STATE_DIR="${KCS_STATE_DIR:-$HOME/Library/Application Support/kindle-clippings-sync}"
KCS_MOUNT_DELAY="${KCS_MOUNT_DELAY:-5}"
KCS_RETRIES="${KCS_RETRIES:-3}"
KCS_RETRY_INTERVAL="${KCS_RETRY_INTERVAL:-5}"
KCS_NOTIFY="${KCS_NOTIFY:-1}"
KCS_REQUIRE_MARKER="${KCS_REQUIRE_MARKER:-1}"
KCS_MAX_BACKUPS="${KCS_MAX_BACKUPS:-0}"

if [ "$NOW" = 1 ]; then
  KCS_MOUNT_DELAY=0
  KCS_RETRIES=1
fi

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

# Escapa texto para uma string AppleScript entre aspas.
as_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

notify() {
  local msg="$1" title="${2:-Kindle}"
  [ "$KCS_NOTIFY" = 1 ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$(as_escape "$msg")\" with title \"$(as_escape "$title")\"" \
    >/dev/null 2>&1 || log "aviso: falha ao exibir notificacao"
}

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

# Imprime o caminho do primeiro "My Clippings.txt" de um Kindle montado.
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
  # Nomes com data ISO ordenam cronologicamente.
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
- Total: $entries $label (contadas pelos separadores \`==========\`)
- Arquivo copiado: [[My Clippings.txt]]
- Origem no Kindle: \`$src\`
- Backups guardados em \`backups/\`: $backups

## Como funciona

Sempre que o Kindle é conectado ao Mac via USB, o launchd executa o script. Se o conteúdo de \`My Clippings.txt\` mudou desde a última sincronização (comparação por SHA-256), o arquivo é copiado para esta pasta e uma cópia datada vai para \`backups/\`. O assistente de leitura usa esse arquivo para gerar as notas de capítulo de cada livro.
NOTE
  mv -f "$tmp" "$note"
}

# --- execucao ---------------------------------------------------------------
mkdir -p "$(dirname "$KCS_LOG")" 2>/dev/null
rotate_log

if [ "$KCS_MOUNT_DELAY" -gt 0 ] 2>/dev/null; then
  sleep "$KCS_MOUNT_DELAY"
fi

if [ ! -d "$KCS_VOLUMES_ROOT" ]; then
  exit 0
fi
if ! ls "$KCS_VOLUMES_ROOT" >/dev/null 2>&1; then
  log "erro: sem permissão para listar $KCS_VOLUMES_ROOT (verifique Volumes Removíveis / Acesso Total ao Disco para /bin/bash)"
  exit 1
fi

SRC=""
attempt=1
while :; do
  SRC="$(find_clippings)" && break
  SRC=""
  [ "$attempt" -ge "$KCS_RETRIES" ] && break
  attempt=$((attempt + 1))
  sleep "$KCS_RETRY_INTERVAL"
done

if [ -z "$SRC" ]; then
  # Nenhum Kindle: sair em silencio (o launchd dispara em qualquer montagem).
  exit 0
fi

# Lock por mkdir (atomico, existe em qualquer Unix; flock nao vem no macOS).
mkdir -p "$KCS_STATE_DIR" 2>/dev/null || { log "erro: não consegui criar $KCS_STATE_DIR"; exit 1; }
LOCK="$KCS_STATE_DIR/lock"
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
echo "$$" >"$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
trap 'exit 1' INT TERM HUP

if [ -n "$KCS_DEST" ]; then
  DEST="$KCS_DEST"
else
  if [ ! -d "$KCS_VAULT" ]; then
    log "erro: cofre do Obsidian não encontrado: $KCS_VAULT"
    notify "Cofre do Obsidian não encontrado. Veja o log." "Kindle: erro"
    exit 1
  fi
  DEST="$KCS_VAULT/$KCS_DEST_SUBDIR"
fi
DEST_FILE="$DEST/My Clippings.txt"
BACKUP_DIR="$DEST/backups"
NOTE_FILE="$DEST/Kindle Sync.md"
STATE_HASH="$KCS_STATE_DIR/last.sha256"

SRC_HASH="$(sha256_of "$SRC")"
if [ -z "$SRC_HASH" ]; then
  log "erro: não consegui ler $SRC"
  exit 1
fi

LAST_HASH="$(cat "$STATE_HASH" 2>/dev/null)"
if [ "$FORCE" != 1 ] && [ "$SRC_HASH" = "$LAST_HASH" ] && [ -f "$DEST_FILE" ] &&
  [ "$(sha256_of "$DEST_FILE")" = "$SRC_HASH" ]; then
  log "sem alterações ($SRC, sha256 ${SRC_HASH:0:12})"
  exit 0
fi

if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
  log "erro: não consegui criar $BACKUP_DIR (permissão do iCloud Drive? veja o README)"
  notify "Erro ao gravar no cofre. Veja o log." "Kindle: erro"
  exit 1
fi

# Copia para um temporario no destino, confere o hash e troca atomicamente.
TMP="$DEST/.My Clippings.txt.tmp.$$"
ok=0
for _ in 1 2 3; do
  if cp "$SRC" "$TMP" 2>>"$KCS_LOG" && [ "$(sha256_of "$TMP")" = "$SRC_HASH" ]; then
    ok=1
    break
  fi
  sleep 1
  SRC_HASH="$(sha256_of "$SRC")"
done
if [ "$ok" != 1 ]; then
  rm -f "$TMP"
  log "erro: falha ao copiar $SRC para $DEST (permissão? veja o README)"
  notify "Erro ao copiar os destaques. Veja o log." "Kindle: erro"
  exit 1
fi
mv -f "$TMP" "$DEST_FILE"

STAMP="$(date '+%Y-%m-%d %H%M%S')"
BACKUP="$(backup_path "$BACKUP_DIR" "$STAMP")"
cp "$DEST_FILE" "$BACKUP" || log "aviso: falha ao criar backup $BACKUP"
prune_backups "$BACKUP_DIR" "$KCS_MAX_BACKUPS"

ENTRIES="$(count_entries "$DEST_FILE")"
NBACKUPS="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'My Clippings *.txt' | wc -l | tr -d ' ')"
write_note "$NOTE_FILE" "$ENTRIES" "$SRC" "$SRC_HASH" "$NBACKUPS" \
  "$(date '+%Y-%m-%dT%H:%M:%S')" "$(date '+%d/%m/%Y')" "$(date '+%H:%M:%S')"

printf '%s\n' "$SRC_HASH" >"$STATE_HASH"

log "sincronizado: $ENTRIES entradas de $SRC para $DEST_FILE (backup: $(basename "$BACKUP"))"
if [ "$ENTRIES" = 1 ]; then
  notify "Kindle sincronizado: 1 destaque" "Kindle"
else
  notify "Kindle sincronizado: $ENTRIES destaques" "Kindle"
fi
exit 0
