#!/bin/bash
# Instala o kindle-clippings-sync como LaunchAgent do usuario (macOS).
# Pode ser executado de novo quantas vezes quiser: sobrescreve script, helper e
# plist, preserva a config existente (salvo opcoes novas) e recarrega o job.
#
# Uso: ./install.sh [opcoes]
#   --vault CAMINHO        cofre do Obsidian
#   --dest-subdir PASTA    pasta dentro do cofre (padrao: 05 Conhecimento/Leituras/_Kindle)
#   --prefix DIR           onde instalar o script (padrao: ~/.local/bin)
#   --install-deps         instala o libmtp com o Homebrew se faltar (brew install libmtp)
#   --product-id N|any     idProduct do Kindle para o gatilho USB (padrao: 39297 = 0x9981;
#                          "any" casa qualquer aparelho Amazon, idVendor 6473)
#   --interval SEGUNDOS    StartInterval de reserva (padrao: 120; 0 desliga)
#   --no-iokit             nao usa o gatilho de conexao USB (so StartInterval/StartOnMount)
#   --helper-bin CAMINHO   usa um kcs-iokit-trigger ja compilado em vez de compilar
#   --run-now              depois de instalar, dispara o job pelo launchd e mostra o log
#   --test                 depois de instalar, roda o script em primeiro plano (--now)
#   --no-load              nao carrega o job no launchd
#   -h, --help             esta ajuda

set -eu

LABEL="digital.gabriel.kindle-clippings-sync"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_SCRIPT="$REPO_DIR/bin/kindle-clippings-sync.sh"
HELPER_SRC="$REPO_DIR/helper/kcs-iokit-trigger.c"
TEMPLATE="$REPO_DIR/launchd/$LABEL.plist.template"

CONFIG_DIR="$HOME/.config/kindle-clippings-sync"
CONFIG_FILE="$CONFIG_DIR/config.env"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/kindle-clippings-sync.log"
LIBEXEC="$HOME/.local/libexec/kindle-clippings-sync"
HELPER="$LIBEXEC/kcs-iokit-trigger"

# Chaves gravadas na config (valores existentes sao preservados em reinstalacoes).
CONFIG_KEYS="KCS_VAULT KCS_DEST_SUBDIR KCS_SOURCE KCS_NOTIFY KCS_MAX_BACKUPS \
KCS_USB_VENDOR_ID KCS_USB_PRODUCT_ID KCS_START_INTERVAL KCS_IOKIT_TRIGGER \
KCS_MTP_DELAY KCS_MTP_RETRIES KCS_MTP_RETRY_INTERVAL KCS_MTP_TIMEOUT \
KCS_MTP_RESYNC_SECONDS KCS_MTP_KILL_PTPCAMERAD \
KCS_MOUNT_DELAY KCS_RETRIES KCS_RETRY_INTERVAL KCS_REQUIRE_MARKER"

default_for() {
  case "$1" in
    KCS_VAULT) echo "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents" ;;
    KCS_DEST_SUBDIR) echo "05 Conhecimento/Leituras/_Kindle" ;;
    KCS_SOURCE) echo auto ;;
    KCS_NOTIFY) echo 1 ;;
    KCS_MAX_BACKUPS) echo 0 ;;
    KCS_USB_VENDOR_ID) echo 6473 ;;
    KCS_USB_PRODUCT_ID) echo 39297 ;;
    KCS_START_INTERVAL) echo 120 ;;
    KCS_IOKIT_TRIGGER) echo 1 ;;
    KCS_MTP_DELAY) echo 3 ;;
    KCS_MTP_RETRIES) echo 4 ;;
    KCS_MTP_RETRY_INTERVAL) echo 10 ;;
    KCS_MTP_TIMEOUT) echo 180 ;;
    KCS_MTP_RESYNC_SECONDS) echo 0 ;;
    KCS_MTP_KILL_PTPCAMERAD) echo 0 ;;
    KCS_MOUNT_DELAY) echo 5 ;;
    KCS_RETRIES) echo 3 ;;
    KCS_RETRY_INTERVAL) echo 5 ;;
    KCS_REQUIRE_MARKER) echo 1 ;;
  esac
}

OPT_VAULT=""
OPT_SUBDIR=""
OPT_PRODUCT=""
OPT_INTERVAL=""
OPT_IOKIT=""
HELPER_BIN=""
PREFIX="${KCS_PREFIX:-$HOME/.local/bin}"
INSTALL_DEPS=0
RUN_NOW=0
RUN_TEST=0
LOAD=1

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vault) OPT_VAULT="${2:?--vault precisa de um caminho}"; shift 2 ;;
    --dest-subdir) OPT_SUBDIR="${2:?--dest-subdir precisa de uma pasta}"; shift 2 ;;
    --prefix) PREFIX="${2:?--prefix precisa de um diretorio}"; shift 2 ;;
    --install-deps) INSTALL_DEPS=1; shift ;;
    --product-id) OPT_PRODUCT="${2:?--product-id precisa de um numero ou any}"; shift 2 ;;
    --interval) OPT_INTERVAL="${2:?--interval precisa de segundos}"; shift 2 ;;
    --no-iokit) OPT_IOKIT=0; shift ;;
    --helper-bin) HELPER_BIN="${2:?--helper-bin precisa de um caminho}"; shift 2 ;;
    --run-now) RUN_NOW=1; shift ;;
    --test) RUN_TEST=1; shift ;;
    --no-load) LOAD=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "opcao desconhecida: $1" >&2; usage >&2; exit 2 ;;
  esac
done

INSTALLED="$PREFIX/kindle-clippings-sync"

# Precedencia: opcoes > variaveis de ambiente > config existente > padroes.
for k in $CONFIG_KEYS; do eval "__env_$k=\"\${$k-}\""; eval "$k=''"; done
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi
for k in $CONFIG_KEYS; do
  eval "__e=\"\${__env_$k}\""
  # shellcheck disable=SC2154
  if [ -n "$__e" ]; then eval "$k=\"\$__e\""; fi
done
[ -n "$OPT_VAULT" ] && KCS_VAULT="$OPT_VAULT"
[ -n "$OPT_SUBDIR" ] && KCS_DEST_SUBDIR="$OPT_SUBDIR"
[ -n "$OPT_PRODUCT" ] && KCS_USB_PRODUCT_ID="$OPT_PRODUCT"
[ -n "$OPT_INTERVAL" ] && KCS_START_INTERVAL="$OPT_INTERVAL"
[ -n "$OPT_IOKIT" ] && KCS_IOKIT_TRIGGER="$OPT_IOKIT"
for k in $CONFIG_KEYS; do
  eval "__cur=\"\${$k-}\""
  # shellcheck disable=SC2154
  if [ -z "$__cur" ]; then __d="$(default_for "$k")"; eval "$k=\"\$__d\""; fi
done

case "$KCS_USB_PRODUCT_ID" in any|[0-9]*) ;; *) echo "--product-id invalido: $KCS_USB_PRODUCT_ID" >&2; exit 2 ;; esac
case "$KCS_START_INTERVAL" in *[!0-9]*|'') echo "--interval invalido: $KCS_START_INTERVAL" >&2; exit 2 ;; esac
case "$KCS_USB_VENDOR_ID" in *[!0-9]*|'') echo "KCS_USB_VENDOR_ID invalido: $KCS_USB_VENDOR_ID" >&2; exit 2 ;; esac

# Aspas simples seguras para shell (o caminho do cofre tem espacos e til).
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

find_tool() {
  local d
  if command -v "$1" >/dev/null 2>&1; then command -v "$1"; return 0; fi
  for d in /opt/homebrew/bin /usr/local/bin; do
    [ -x "$d/$1" ] && { echo "$d/$1"; return 0; }
  done
  return 1
}

[ -f "$SRC_SCRIPT" ] || { echo "nao achei $SRC_SCRIPT" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "nao achei $TEMPLATE" >&2; exit 1; }

if [ ! -d "$KCS_VAULT" ]; then
  echo "aviso: o cofre ainda nao existe ou nao esta acessivel: $KCS_VAULT" >&2
fi

# --- dependencias: libmtp --------------------------------------------------
echo "==> Verificando libmtp (mtp-files, mtp-folders, mtp-getfile)"
if MTPF="$(find_tool mtp-files)" && find_tool mtp-getfile >/dev/null; then
  echo "    ok: $MTPF"
elif [ "$INSTALL_DEPS" = 1 ]; then
  if BREW="$(find_tool brew)"; then
    echo "    instalando: $BREW install libmtp"
    "$BREW" install libmtp
    find_tool mtp-files >/dev/null || { echo "erro: libmtp continua ausente" >&2; exit 1; }
  else
    echo "erro: Homebrew nao encontrado. Instale em https://brew.sh e rode: brew install libmtp" >&2
    exit 1
  fi
else
  echo "    AVISO: libmtp nao encontrado. Kindles MTP (Paperwhite recentes) precisam dele:"
  echo "           brew install libmtp      (ou rode ./install.sh --install-deps)"
  echo "    Sem ele so funciona o modo /Volumes (Kindles antigos)."
fi

# --- script ----------------------------------------------------------------
echo "==> Instalando script em $INSTALLED"
mkdir -p "$PREFIX"
cp "$SRC_SCRIPT" "$INSTALLED.tmp.$$"
chmod 755 "$INSTALLED.tmp.$$"
mv -f "$INSTALLED.tmp.$$" "$INSTALLED"

# --- helper do evento de IOKit ---------------------------------------------
USE_HELPER=0
if [ "$KCS_IOKIT_TRIGGER" = 1 ]; then
  mkdir -p "$LIBEXEC"
  if [ -n "$HELPER_BIN" ]; then
    [ -x "$HELPER_BIN" ] || { echo "erro: --helper-bin nao e executavel: $HELPER_BIN" >&2; exit 1; }
    cp "$HELPER_BIN" "$HELPER.tmp.$$" && chmod 755 "$HELPER.tmp.$$" && mv -f "$HELPER.tmp.$$" "$HELPER"
    USE_HELPER=1
  elif [ "${KCS_HELPER_BUILD:-1}" = 1 ] && [ "$(uname -s)" = Darwin ] && xcode-select -p >/dev/null 2>&1 &&
    CC="$(xcrun --find clang 2>/dev/null || command -v /usr/bin/cc)" && [ -x "$CC" ]; then
    echo "==> Compilando $HELPER ($CC)"
    if "$CC" -O2 -Wall -o "$HELPER.tmp.$$" "$HELPER_SRC" 2>/tmp/kcs-helper-build.log; then
      mv -f "$HELPER.tmp.$$" "$HELPER"
      USE_HELPER=1
    else
      rm -f "$HELPER.tmp.$$"
      echo "    AVISO: falha ao compilar (veja /tmp/kcs-helper-build.log)."
    fi
  else
    echo "==> AVISO: sem compilador C (rode: xcode-select --install)."
  fi
  if [ "$USE_HELPER" != 1 ]; then
    echo "    Sem o helper, o gatilho de conexao USB fica desligado (ele relancaria o job em loop)."
    echo "    O Kindle sera detectado pelo StartInterval (a cada ${KCS_START_INTERVAL}s)."
  fi
fi

# --- config ----------------------------------------------------------------
echo "==> Gravando config em $CONFIG_FILE"
mkdir -p "$CONFIG_DIR"
{
  echo "# Config do kindle-clippings-sync (gerada pelo install.sh em $(date '+%Y-%m-%d %H:%M:%S'))."
  echo "# Pode editar a mao; rode ./install.sh de novo para aplicar mudancas de gatilho."
  echo "# Variaveis de ambiente com o mesmo nome tem prioridade."
  for k in $CONFIG_KEYS; do
    eval "__v=\"\${$k}\""
    # shellcheck disable=SC2154
    echo "$k=$(sq "$__v")"
  done
} >"$CONFIG_FILE.tmp.$$"
mv -f "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE"

# --- plist -----------------------------------------------------------------
echo "==> Gerando $PLIST"
mkdir -p "$AGENTS_DIR" "$(dirname "$LOG_FILE")"
BLOCKS="$(mktemp -d "${TMPDIR:-/tmp}/kcs-install.XXXXXX")"
trap 'rm -rf "$BLOCKS"' EXIT

{
  if [ "$USE_HELPER" = 1 ]; then
    printf '\t\t<string>%s</string>\n' "$(xml_escape "$HELPER")"
  fi
  printf '\t\t<string>/bin/bash</string>\n'
  printf '\t\t<string>%s</string>\n' "$(xml_escape "$INSTALLED")"
} >"$BLOCKS/args"

: >"$BLOCKS/events"
if [ "$USE_HELPER" = 1 ]; then
  {
    printf '\t<!-- Dispara quando o Kindle (USB/MTP) e conectado. O helper consome o evento\n'
    printf '\t     com xpc_set_event_stream_handler para o launchd nao relancar em loop. -->\n'
    printf '\t<key>LaunchEvents</key>\n\t<dict>\n'
    printf '\t\t<key>com.apple.iokit.matching</key>\n\t\t<dict>\n'
    printf '\t\t\t<key>%s.usb</key>\n\t\t\t<dict>\n' "$LABEL"
    printf '\t\t\t\t<key>IOProviderClass</key>\n\t\t\t\t<string>IOUSBHostDevice</string>\n'
    printf '\t\t\t\t<key>idVendor</key>\n\t\t\t\t<integer>%s</integer>\n' "$KCS_USB_VENDOR_ID"
    if [ "$KCS_USB_PRODUCT_ID" != any ]; then
      printf '\t\t\t\t<key>idProduct</key>\n\t\t\t\t<integer>%s</integer>\n' "$KCS_USB_PRODUCT_ID"
    fi
    printf '\t\t\t\t<key>IOMatchLaunchStream</key>\n\t\t\t\t<true/>\n'
    printf '\t\t\t</dict>\n\t\t</dict>\n\t</dict>\n'
  } >"$BLOCKS/events"
fi

: >"$BLOCKS/interval"
if [ "$KCS_START_INTERVAL" -gt 0 ]; then
  {
    printf '\t<!-- Reserva: roda a cada N s; sai na hora se o ioreg nao mostra um Kindle. -->\n'
    printf '\t<key>StartInterval</key>\n\t<integer>%s</integer>\n' "$KCS_START_INTERVAL"
  } >"$BLOCKS/interval"
fi

sed -e "s|__LABEL__|$(sed_escape "$(xml_escape "$LABEL")")|g" \
    -e "s|__CONFIG__|$(sed_escape "$(xml_escape "$CONFIG_FILE")")|g" \
    -e "s|__LOG__|$(sed_escape "$(xml_escape "$LOG_FILE")")|g" \
    "$TEMPLATE" |
  awk -v a="$BLOCKS/args" -v e="$BLOCKS/events" -v i="$BLOCKS/interval" '
    function cat(f,   l) { while ((getline l < f) > 0) print l; close(f) }
    /^__PROGRAM_ARGUMENTS__$/ { cat(a); next }
    /^__LAUNCH_EVENTS__$/     { cat(e); next }
    /^__START_INTERVAL__$/    { cat(i); next }
    { print }' >"$PLIST.tmp.$$"
mv -f "$PLIST.tmp.$$" "$PLIST"
chmod 644 "$PLIST"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST"
fi

# --- launchd ---------------------------------------------------------------
HAVE_LAUNCHCTL=0
if [ "${KCS_SKIP_LAUNCHCTL:-0}" != 1 ] && command -v launchctl >/dev/null 2>&1; then
  HAVE_LAUNCHCTL=1
fi
DOMAIN="gui/$(id -u)"

if [ "$LOAD" = 1 ] && [ "$HAVE_LAUNCHCTL" = 1 ]; then
  echo "==> Carregando no launchd ($DOMAIN/$LABEL)"
  # Remove a versao anterior, se houver (por isso o script pode ser re-executado).
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl unload "$PLIST" >/dev/null 2>&1 || true
  loaded=0
  for _ in 1 2 3 4 5; do
    if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then loaded=1; break; fi
    sleep 1 # o bootout e assincrono; espera o job sair
  done
  if [ "$loaded" != 1 ]; then
    echo "    bootstrap falhou; tentando launchctl load -w"
    launchctl load -w "$PLIST"
  fi
  launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl list | grep -q "$LABEL"; then
    echo "    ok: job carregado"
  else
    echo "    aviso: nao consegui confirmar que o job esta carregado" >&2
  fi
elif [ "$LOAD" = 1 ]; then
  echo "==> launchctl indisponivel; plist gerado mas nao carregado"
fi

if [ "$RUN_TEST" = 1 ]; then
  echo "==> Rodando em primeiro plano: $INSTALLED --now"
  KCS_CONFIG="$CONFIG_FILE" /bin/bash "$INSTALLED" --now || echo "    o script saiu com erro; veja $LOG_FILE" >&2
fi

if [ "$RUN_NOW" = 1 ]; then
  if [ "$HAVE_LAUNCHCTL" = 1 ]; then
    before=0
    [ -f "$LOG_FILE" ] && before="$(wc -l <"$LOG_FILE" | tr -d ' ')"
    echo "==> Disparando pelo launchd (launchctl kickstart -k $DOMAIN/$LABEL)"
    launchctl kickstart -k "$DOMAIN/$LABEL"
    wait_s=$((KCS_MTP_DELAY + KCS_MTP_RETRIES * KCS_MTP_RETRY_INTERVAL + 30))
    echo "    aguardando ate ${wait_s}s pelo log..."
    i=0
    while [ "$i" -lt "$wait_s" ]; do
      now=0
      [ -f "$LOG_FILE" ] && now="$(wc -l <"$LOG_FILE" | tr -d ' ')"
      if [ "$now" -gt "$before" ] && ! launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running'; then
        break
      fi
      sleep 1
      i=$((i + 1))
    done
    if [ -f "$LOG_FILE" ] && [ "$(wc -l <"$LOG_FILE" | tr -d ' ')" -gt "$before" ]; then
      tail -n +"$((before + 1))" "$LOG_FILE"
    else
      echo "    nenhuma linha nova no log. Kindle conectado? Ja sincronizado nesta conexao?"
      echo "    (sem Kindle, ou se ja sincronizou nesta conexao, o script sai em silencio; use --test)"
    fi
  else
    echo "==> launchctl indisponivel; rodando direto"
    KCS_CONFIG="$CONFIG_FILE" /bin/bash "$INSTALLED" --now
  fi
fi

echo
echo "Pronto. Cofre: $KCS_VAULT"
echo "Destino: $KCS_VAULT/$KCS_DEST_SUBDIR"
echo "Gatilho USB (IOKit): $([ "$USE_HELPER" = 1 ] && echo "ligado (idVendor $KCS_USB_VENDOR_ID, idProduct $KCS_USB_PRODUCT_ID)" || echo desligado)"
echo "StartInterval: ${KCS_START_INTERVAL}s"
echo "Log: $LOG_FILE"
