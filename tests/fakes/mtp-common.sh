# shellcheck shell=bash
# Funcoes compartilhadas pelos mtp-* falsos. Formato copiado do libmtp 1.1.22
# (examples/files.c, folders.c, connect.c/getfile.c e src/libusb1-glue.c).
# Estado em $FAKE_DIR:
#   manifest       linhas "id<TAB>parent<TAB>nome<TAB>arquivo local" (arquivos)
#   folders        saida pronta das pastas ("id<TAB>  nome")
#   busy           contador: enquanto > 0, cada chamada falha como "ocupado"
#   nodevice       se existir: nenhum aparelho MTP
#   hang           se existir: o comando trava
#   getfile-nodev  se existir: mtp-getfile responde "No devices."
fake_prelude() {
  echo "$1" >>"$FAKE_DIR/calls"
  [ -e "$FAKE_DIR/hang" ] && sleep 30
  return 0
}
fake_busy() { # imprime a falha de claim e retorna 0 se "ocupado"
  local n
  n="$(cat "$FAKE_DIR/busy" 2>/dev/null || echo 0)"
  [ "$n" -gt 0 ] || return 1
  echo $((n - 1)) >"$FAKE_DIR/busy"
  printf 'libusb_claim_interface() reports device is busy, likely in use by GVFS or KDE MTP device handling already' >&2
  printf 'LIBMTP PANIC: Unable to initialize device\n' >&2
  printf 'Unable to open raw device 0\n' >&2
  return 0
}
fake_unknown_warning() {
  printf 'Device 0 (VID=1949 and PID=9981) is UNKNOWN in libmtp v1.1.22.\n' >&2
  printf 'Please report this VID/PID and the device model to the libmtp development team\n' >&2
}
