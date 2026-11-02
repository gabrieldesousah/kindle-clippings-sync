#!/bin/bash
# Instala o kindle-clippings-sync como LaunchAgent do usuario (macOS).
# Pode ser executado de novo quantas vezes quiser: sobrescreve script e plist,
# preserva a config existente (a menos que voce passe novas opcoes) e recarrega o job.
#
# Uso: ./install.sh [opcoes]
#   --vault CAMINHO        cofre do Obsidian
#   --dest-subdir PASTA    pasta dentro do cofre (padrao: 05 Conhecimento/Leituras/_Kindle)
#   --prefix DIR           onde instalar o script (padrao: ~/.local/bin)
#   --run-now              depois de instalar, dispara o job pelo launchd e mostra o log
#   --test                 depois de instalar, roda o script em primeiro plano (--now)
#   --no-load              nao carrega o job no launchd
#   -h, --help             esta ajuda

set -eu

LABEL="digital.gabriel.kindle-clippings-sync"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_SCRIPT="$REPO_DIR/bin/kindle-clippings-sync.sh"
TEMPLATE="$REPO_DIR/launchd/$LABEL.plist.template"

CONFIG_DIR="$HOME/.config/kindle-clippings-sync"
CONFIG_FILE="$CONFIG_DIR/config.env"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/kindle-clippings-sync.log"

OPT_VAULT=""
OPT_SUBDIR=""
PREFIX="${KCS_PREFIX:-$HOME/.local/bin}"
RUN_NOW=0
RUN_TEST=0
LOAD=1

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vault) OPT_VAULT="${2:?--vault precisa de um caminho}"; shift 2 ;;
    --dest-subdir) OPT_SUBDIR="${2:?--dest-subdir precisa de uma pasta}"; shift 2 ;;
    --prefix) PREFIX="${2:?--prefix precisa de um diretorio}"; shift 2 ;;
    --run-now) RUN_NOW=1; shift ;;
    --test) RUN_TEST=1; shift ;;
    --no-load) LOAD=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "opcao desconhecida: $1" >&2; usage >&2; exit 2 ;;
  esac
done

INSTALLED="$PREFIX/kindle-clippings-sync"

# Precedencia: opcoes > variaveis de ambiente > config existente > padroes.
ENV_VAULT="${KCS_VAULT-}"
ENV_SUBDIR="${KCS_DEST_SUBDIR-}"
KCS_VAULT=""
KCS_DEST_SUBDIR=""
KCS_MOUNT_DELAY=""
KCS_RETRIES=""
KCS_RETRY_INTERVAL=""
KCS_NOTIFY=""
KCS_REQUIRE_MARKER=""
KCS_MAX_BACKUPS=""
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi
[ -n "$ENV_VAULT" ] && KCS_VAULT="$ENV_VAULT"
[ -n "$ENV_SUBDIR" ] && KCS_DEST_SUBDIR="$ENV_SUBDIR"
[ -n "$OPT_VAULT" ] && KCS_VAULT="$OPT_VAULT"
[ -n "$OPT_SUBDIR" ] && KCS_DEST_SUBDIR="$OPT_SUBDIR"
KCS_VAULT="${KCS_VAULT:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents}"
KCS_DEST_SUBDIR="${KCS_DEST_SUBDIR:-05 Conhecimento/Leituras/_Kindle}"
KCS_MOUNT_DELAY="${KCS_MOUNT_DELAY:-5}"
KCS_RETRIES="${KCS_RETRIES:-3}"
KCS_RETRY_INTERVAL="${KCS_RETRY_INTERVAL:-5}"
KCS_NOTIFY="${KCS_NOTIFY:-1}"
KCS_REQUIRE_MARKER="${KCS_REQUIRE_MARKER:-1}"
KCS_MAX_BACKUPS="${KCS_MAX_BACKUPS:-0}"

# Aspas simples seguras para shell (o caminho do cofre tem espacos e til).
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

[ -f "$SRC_SCRIPT" ] || { echo "nao achei $SRC_SCRIPT" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "nao achei $TEMPLATE" >&2; exit 1; }

if [ ! -d "$KCS_VAULT" ]; then
  echo "aviso: o cofre ainda nao existe ou nao esta acessivel: $KCS_VAULT" >&2
fi

echo "==> Instalando script em $INSTALLED"
mkdir -p "$PREFIX"
cp "$SRC_SCRIPT" "$INSTALLED.tmp.$$"
chmod 755 "$INSTALLED.tmp.$$"
mv -f "$INSTALLED.tmp.$$" "$INSTALLED"

echo "==> Gravando config em $CONFIG_FILE"
mkdir -p "$CONFIG_DIR"
{
  echo "# Config do kindle-clippings-sync (gerada pelo install.sh em $(date '+%Y-%m-%d %H:%M:%S'))."
  echo "# Pode editar a mao. Variaveis de ambiente com o mesmo nome tem prioridade."
  echo "KCS_VAULT=$(sq "$KCS_VAULT")"
  echo "KCS_DEST_SUBDIR=$(sq "$KCS_DEST_SUBDIR")"
  echo "KCS_MOUNT_DELAY=$(sq "$KCS_MOUNT_DELAY")"
  echo "KCS_RETRIES=$(sq "$KCS_RETRIES")"
  echo "KCS_RETRY_INTERVAL=$(sq "$KCS_RETRY_INTERVAL")"
  echo "KCS_NOTIFY=$(sq "$KCS_NOTIFY")"
  echo "KCS_REQUIRE_MARKER=$(sq "$KCS_REQUIRE_MARKER")"
  echo "KCS_MAX_BACKUPS=$(sq "$KCS_MAX_BACKUPS")"
} >"$CONFIG_FILE.tmp.$$"
mv -f "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE"

echo "==> Gerando $PLIST"
mkdir -p "$AGENTS_DIR" "$(dirname "$LOG_FILE")"
sed -e "s|__LABEL__|$(sed_escape "$(xml_escape "$LABEL")")|g" \
    -e "s|__SCRIPT__|$(sed_escape "$(xml_escape "$INSTALLED")")|g" \
    -e "s|__CONFIG__|$(sed_escape "$(xml_escape "$CONFIG_FILE")")|g" \
    -e "s|__LOG__|$(sed_escape "$(xml_escape "$LOG_FILE")")|g" \
    "$TEMPLATE" >"$PLIST.tmp.$$"
mv -f "$PLIST.tmp.$$" "$PLIST"
chmod 644 "$PLIST"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST"
fi

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
    wait_s=$((KCS_MOUNT_DELAY + 15))
    echo "    aguardando ate ${wait_s}s pelo log..."
    i=0
    while [ "$i" -lt "$wait_s" ]; do
      now=0
      [ -f "$LOG_FILE" ] && now="$(wc -l <"$LOG_FILE" | tr -d ' ')"
      [ "$now" -gt "$before" ] && break
      sleep 1
      i=$((i + 1))
    done
    if [ -f "$LOG_FILE" ] && [ "$(wc -l <"$LOG_FILE" | tr -d ' ')" -gt "$before" ]; then
      tail -n +"$((before + 1))" "$LOG_FILE"
    else
      echo "    nenhuma linha nova no log: o Kindle esta conectado? (sem Kindle o script sai em silencio)"
    fi
  else
    echo "==> launchctl indisponivel; rodando direto"
    KCS_CONFIG="$CONFIG_FILE" /bin/bash "$INSTALLED" --now
  fi
fi

echo
echo "Pronto. Cofre: $KCS_VAULT"
echo "Destino: $KCS_VAULT/$KCS_DEST_SUBDIR"
echo "Log: $LOG_FILE"
