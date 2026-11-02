# kindle-clippings-sync

Automação para macOS que copia o arquivo `My Clippings.txt` do Kindle para o cofre do Obsidian toda vez que o Kindle é conectado ao Mac via USB. Depois, o assistente de leitura transforma esses destaques em notas de capítulo de cada livro.

Funciona com os dois tipos de Kindle:

- **MTP** (Kindle Paperwhite e outros modelos recentes): o aparelho **não monta** em `/Volumes`; aparece só como dispositivo USB (Amazon, `idVendor 0x1949`; o Paperwhite testado é `idProduct 0x9981`). O arquivo é baixado com as ferramentas do [libmtp](https://github.com/libmtp/libmtp) (`brew install libmtp`).
- **Armazenamento USB** (modelos antigos): monta em `/Volumes/Kindle` e o arquivo é lido direto de `/Volumes/*/documents/My Clippings.txt`. Continua funcionando como alternativa.

Além do libmtp, usa só o que vem no macOS: `bash` 3.2, `launchd`, `ioreg`, `shasum` e `osascript`. Não precisa de `python3`.

## O que faz

1. O `launchd` dispara o job quando o Kindle é conectado (evento de IOKit), a cada 120 s como reserva e a cada volume montado.
2. O script consulta o `ioreg -p IOUSB` (barato, não abre o MTP). Se não há Kindle no USB, procura em `/Volumes`; se não há nada, sai em silêncio.
3. **Kindle MTP:** se essa conexão USB (o `sessionID` do aparelho) já foi sincronizada, sai na hora. Senão, pega o lock e roda o `kcs-mtp-pull` (programa C deste repositório, ligado ao libmtp), que abre **uma única sessão** MTP, lista só a raiz e a pasta `documents`, baixa `My Clippings.txt` para um arquivo temporário, confere o tamanho e libera o aparelho sem resetar o USB (veja abaixo).
4. **Kindle em `/Volumes`:** só aceita volumes com cara de Kindle (nome com "kindle", pasta `system/`, `.kindle`, `system/version.txt` ou `amazon-cover-bug`).
5. Compara o SHA-256 com o da última sincronização. Se nada mudou, não toca no cofre.
6. Se mudou, copia os bytes exatamente como estão (UTF-8 com BOM e quebras CRLF preservados) para:
   - `<destino>/My Clippings.txt`
   - `<destino>/backups/My Clippings AAAA-MM-DD HHMMSS.txt` (cópia datada)
7. Escreve ou atualiza `<destino>/Kindle Sync.md`, uma nota com frontmatter YAML (tags, data da última sincronização, número de entradas contadas pelos separadores `==========`, origem).
8. Mostra a notificação "Kindle sincronizado: N destaques".
9. Registra tudo em `~/Library/Logs/kindle-clippings-sync.log`.

Execuções simultâneas são seguras (lock por diretório, com detecção de lock obsoleto), a cópia é atômica (temporário, conferência do hash, troca) e cada comando `mtp-*` tem tempo limite.

```mermaid
flowchart TD
    A["Kindle conectado (evento IOKit)<br/>ou StartInterval de 120 s<br/>ou volume montado"] --> B{"ioreg -p IOUSB mostra<br/>um aparelho Amazon 0x1949?"}
    B -- sim --> C{"Esta conexão USB (sessionID)<br/>já foi sincronizada?"}
    C -- sim --> Z1["Sai na hora, sem abrir o MTP"]
    C -- não --> D["kcs-mtp-pull (uma sessão MTP):<br/>acha /documents/My Clippings.txt"]
    D --> E{"MTP ocupado por outro app?"}
    E -- sim --> F["Espera e tenta de novo<br/>(KCS_MTP_RETRIES)"] --> D
    E -- não --> G["Baixa para um temporário<br/>e libera sem reset USB"]
    B -- não --> H{"Existe /Volumes/*/documents/My Clippings.txt<br/>em um volume com cara de Kindle?"}
    H -- não --> Z2["Sai em silêncio"]
    H -- sim --> I["Usa o arquivo do volume"]
    G --> J{"SHA-256 igual ao da última<br/>sincronização e cópia intacta?"}
    I --> J
    J -- sim --> K["Log: sem alterações"]
    J -- não --> L["Copia para o cofre e confere o hash"]
    L --> M["Backup datado em backups/"]
    M --> N["Atualiza Kindle Sync.md"]
    N --> O["Notificação: Kindle sincronizado: N destaques"]
```

## Por que um programa próprio para o MTP (`kcs-mtp-pull`)

No Mac do Gabriel, o Kindle Paperwhite (1949:9981) **caía do USB** logo depois da primeira ferramenta do libmtp terminar. A causa: o libmtp 1.1.23 cadastra esse ID como "Kindle Scribe 32GB" com `DEVICE_FLAGS_ANDROID_BUGS`, que inclui `DEVICE_FLAG_FORCE_RESET_ON_CLOSE` (os flags reportados são `0x18008106`; o bit `0x10000000` é esse). Ao fechar cada sessão o libmtp chama `libusb_reset_device()`, e o Paperwhite some do barramento até ser reconectado. Como `mtp-files`, `mtp-folders` e `mtp-getfile` abrem uma sessão cada, a segunda já não encontrava o aparelho.

O `helper/kcs-mtp-pull.c` resolve isso:

- desliga `FORCE_RESET_ON_CLOSE` na entrada do aparelho antes de abrir (com `--allow-reset` mantém o comportamento original);
- faz tudo numa sessão: raiz, pasta `documents`, download e `LIBMTP_Release_Device` (libera a interface e fecha, sem reset);
- só se não houver `/documents` na raiz faz uma busca limitada no aparelho;
- códigos de saída: `0` ok, `2` sem aparelho/ocupado, `3` arquivo inexistente, `1` outro erro.

Sintoma visto pelo usuário: o Kindle continua na tela do livro, sem mensagem, e segue carregando (LED âmbar), mas some do `ioreg` e do `system_profiler`. Ou seja, a alimentação continua e só o lado de dados USB cai, como acontece depois de um reset que o aparelho não atende. Depois de cada download o script confere o `ioreg` e registra no log "continua no USB depois da sessão MTP" ou "saiu do USB depois da sessão MTP". Se ainda cair mesmo sem o reset, teste `KCS_MTP_PULL_ARGS=--no-release-interface` na config (não libera a interface USB ao fechar). Para o Kindle reaparecer depois de cair é preciso desconectar e conectar o cabo.

O `install.sh` compila com `xcrun clang` e `pkg-config --cflags --libs libmtp` e instala em `~/.local/libexec/kindle-clippings-sync/kcs-mtp-pull`. Se ele não existir, o script volta para as ferramentas `mtp-*` (e avisa no log que isso pode derrubar o Kindle). Depois de um `brew upgrade libmtp`, rode `./install.sh` de novo para recompilar.

Outro detalhe encontrado no Mac: o processo iniciado pelo helper de IOKit herdava o `SIGTERM` ignorado do libdispatch, então o timeout do script não conseguia encerrar o processo vigia e cada comando esperava o tempo limite inteiro. O helper agora restaura os sinais antes do `execv`, e o timeout do script usa `STOP`/`KILL` em vez de depender do `SIGTERM`.

## Gatilho: como o job é disparado

Um Kindle MTP não gera evento de montagem, então o `StartOnMount` não serve para ele. O LaunchAgent combina três gatilhos:

1. **Conexão USB (`LaunchEvents` / `com.apple.iokit.matching`)**, casando `IOProviderClass = IOUSBHostDevice`, `idVendor = 6473` (0x1949) e `idProduct = 39297` (0x9981), com `IOMatchLaunchStream`. É o que faz a sincronização acontecer segundos depois de plugar o cabo.
   - Esse tipo de evento precisa ser "aceito" pelo processo com `xpc_set_event_stream_handler()`. Se o job sair sem isso, o `launchd` considera o evento pendente e relança o job em loop enquanto o aparelho estiver conectado. Um script bash não consegue chamar essa API, por isso existe o `helper/kcs-iokit-trigger.c`: um programa C mínimo que o `install.sh` compila (precisa das Command Line Tools: `xcode-select --install`). Ele consome o evento, espera ~1 s e faz `execv` para `/bin/bash kindle-clippings-sync` (não fica residente).
   - Mesmo assim o evento pode disparar mais de uma vez (no Mac real chegam dois eventos por conexão, entregues ao mesmo processo). Isso é inofensivo: o `launchd` não inicia uma segunda instância enquanto a primeira roda, o script pega um lock antes de abrir o MTP e confere de novo, depois do lock, se a conexão (`sessionID`) já foi sincronizada. Disparos seguintes saem sem abrir o MTP.
   - Sem compilador, o instalador **não** coloca o `LaunchEvents` no plist (para evitar o loop) e avisa; fica valendo o item 2.
2. **`StartInterval` de 120 s (reserva).** Custa só um `ioreg` quando não há Kindle; com o Kindle conectado e já sincronizado, também sai na hora. Ajuste com `--interval N` ou desligue com `--interval 0`.
3. **`StartOnMount`** para Kindles antigos que montam em `/Volumes`.

Por padrão cada conexão é sincronizada uma vez. Se você costuma deixar o Kindle conectado e lendo, use `KCS_MTP_RESYNC_SECONDS=1800` (por exemplo) para ler de novo a cada 30 min enquanto estiver conectado.

Outros Kindles têm outro `idProduct`. Veja o seu com `ioreg -p IOUSB -l -w0 | grep -E '"(USB Product Name|idVendor|idProduct)"'` e reinstale com `--product-id N` (decimal), ou `--product-id any` para qualquer aparelho Amazon.

## Instalação

No Mac, no Terminal:

```bash
xcode-select --install          # se ainda não tiver as Command Line Tools (para o helper)
brew install libmtp             # ou deixe o install.sh fazer isso com --install-deps
git clone https://github.com/<usuario>/kindle-clippings-sync.git ~/Developer/kindle-clippings-sync
cd ~/Developer/kindle-clippings-sync
bash tests/run-tests.sh         # opcional: testes num ambiente falso
./install.sh --install-deps --test
```

Com o Kindle conectado, `./install.sh --run-now` dispara o job pelo próprio `launchd` (o mesmo contexto de permissões do uso real) e mostra o log.

O instalador:

- confere o libmtp (`mtp-files`, `mtp-folders`, `mtp-getfile` no PATH, em `/opt/homebrew/bin` ou `/usr/local/bin`) e mostra `brew install libmtp` se faltar; com `--install-deps` instala pelo Homebrew;
- copia o script para `~/.local/bin/kindle-clippings-sync`;
- compila o helper em `~/.local/libexec/kindle-clippings-sync/kcs-iokit-trigger`;
- grava a config em `~/.config/kindle-clippings-sync/config.env`;
- gera `~/Library/LaunchAgents/digital.gabriel.kindle-clippings-sync.plist` a partir do template em `launchd/`;
- carrega o job com `launchctl bootstrap gui/$(id -u)` (ou `launchctl load -w`, se o primeiro falhar).

Pode rodar o `install.sh` de novo quantas vezes quiser (por exemplo depois de um `git pull`): ele substitui script, helper e plist, recarrega o job e mantém a config existente.

| Opção | Efeito |
| --- | --- |
| `--vault CAMINHO` | caminho do cofre do Obsidian |
| `--dest-subdir PASTA` | pasta dentro do cofre |
| `--prefix DIR` | onde instalar o script (padrão `~/.local/bin`) |
| `--install-deps` | roda `brew install libmtp` se o libmtp faltar |
| `--product-id N\|any` | `idProduct` do gatilho USB (padrão `39297` = 0x9981) |
| `--interval N` | `StartInterval` de reserva em segundos (padrão `120`; `0` desliga) |
| `--no-iokit` | não usa o gatilho de conexão USB |
| `--helper-bin CAMINHO` | usa um helper já compilado |
| `--pull-bin CAMINHO` | usa um `kcs-mtp-pull` já compilado |
| `--test` | depois de instalar, roda o script no Terminal (`--now`) |
| `--run-now` | depois de instalar, dispara via `launchctl kickstart` e mostra o log |
| `--no-load` | só gera os arquivos, sem carregar no `launchd` |

## Desinstalação

```bash
./uninstall.sh           # remove o LaunchAgent, o script e o helper
./uninstall.sh --purge   # também apaga config, estado interno e log
```

Nada dentro do cofre do Obsidian é apagado: a cópia, os backups e a nota continuam lá. O libmtp continua instalado (`brew uninstall libmtp` se quiser).

## Configuração

O arquivo `~/.config/kindle-clippings-sync/config.env` é um shell simples e pode ser editado à mão. Variáveis de ambiente com o mesmo nome têm prioridade. Mudanças de gatilho (`KCS_USB_PRODUCT_ID`, `KCS_START_INTERVAL`, `KCS_IOKIT_TRIGGER`) só valem depois de rodar `./install.sh` de novo.

| Variável | Padrão | Descrição |
| --- | --- | --- |
| `KCS_VAULT` | `~/Library/Mobile Documents/iCloud~md~obsidian/Documents` | cofre do Obsidian |
| `KCS_DEST_SUBDIR` | `05 Conhecimento/Leituras/_Kindle` | pasta dentro do cofre |
| `KCS_DEST` | (vazio) | caminho absoluto do destino; ignora as duas anteriores |
| `KCS_SOURCE` | `auto` | `auto` (MTP, depois `/Volumes`), `mtp` ou `volumes` |
| `KCS_NOTIFY` | `1` | `0` desliga a notificação |
| `KCS_MAX_BACKUPS` | `0` | manter só os N backups mais recentes (`0` mantém todos) |
| `KCS_USB_VENDOR_ID` | `6473` | `idVendor` do Kindle (0x1949, Amazon) |
| `KCS_USB_PRODUCT_ID` | `39297` | `idProduct` do gatilho USB (0x9981) ou `any` |
| `KCS_START_INTERVAL` | `120` | `StartInterval` de reserva |
| `KCS_IOKIT_TRIGGER` | `1` | `0` desliga o gatilho de conexão USB |
| `KCS_MTP_PULL` | (vazio) | caminho do `kcs-mtp-pull`; vazio = `~/.local/libexec/kindle-clippings-sync/kcs-mtp-pull`; `none` = usar as ferramentas `mtp-*` |
| `KCS_MTP_PULL_ARGS` | (vazio) | opções extras do `kcs-mtp-pull`, ex.: `--no-release-interface` |
| `KCS_MTP_BIN_DIR` | (vazio) | pasta dos `mtp-*`; vazio = PATH, `/opt/homebrew/bin`, `/usr/local/bin` |
| `KCS_MTP_DELAY` | `3` | segundos de espera depois de detectar o Kindle |
| `KCS_MTP_RETRIES` | `4` | tentativas quando o MTP está ocupado |
| `KCS_MTP_RETRY_INTERVAL` | `10` | segundos entre tentativas |
| `KCS_MTP_TIMEOUT` | `180` | tempo máximo de cada comando `mtp-*` |
| `KCS_MTP_RESYNC_SECONDS` | `0` | `0` = uma vez por conexão; N = de novo a cada N s conectado |
| `KCS_MTP_KILL_PTPCAMERAD` | `0` | `1` = encerra o `ptpcamerad` do macOS se o MTP estiver ocupado |
| `KCS_VOLUMES_ROOT` | `/Volumes` | onde procurar volumes montados |
| `KCS_MOUNT_DELAY` | `5` | espera depois de uma montagem recente |
| `KCS_RETRIES` / `KCS_RETRY_INTERVAL` | `3` / `5` | tentativas em `/Volumes` |
| `KCS_REQUIRE_MARKER` | `1` | `0` aceita qualquer volume com `documents/My Clippings.txt` |
| `KCS_LOG` | `~/Library/Logs/kindle-clippings-sync.log` | arquivo de log |
| `KCS_STATE_DIR` | `~/Library/Application Support/kindle-clippings-sync` | hash, sessão USB e lock |

O caminho do cofre tem espaços e til, então use sempre aspas simples na config, como o instalador já faz:

```bash
KCS_VAULT='/Users/gabrielhenrique/Library/Mobile Documents/iCloud~md~obsidian/Documents'
```

Execução manual:

```bash
~/.local/bin/kindle-clippings-sync --now           # sem espera e ignorando "já sincronizado nesta conexão"
~/.local/bin/kindle-clippings-sync --now --force   # copia mesmo sem mudança
```

## Kindle ocupado por outro app (MTP)

Só um programa por vez consegue abrir um aparelho MTP. Se outro app estiver com o Kindle, o libmtp falha com mensagens como `libusb_claim_interface() reports device is busy`, `Unable to open raw device 0` ou `LIBMTP PANIC: Unable to initialize device`. Os suspeitos de sempre:

- **Android File Transfer** (e o processo `Android File Transfer Agent`, que abre sozinho quando um aparelho MTP é conectado);
- **OpenMTP**, **MacDroid** e similares;
- o app **Kindle** / **Send to Kindle** da Amazon;
- **Captura de Imagem**, **Fotos** ou o serviço do sistema `ptpcamerad`, que às vezes pega aparelhos MTP/PTP.

O que o script faz: tenta de novo `KCS_MTP_RETRIES` vezes, registra no log quais desses processos estão rodando e a mensagem do libusb, e mostra uma notificação "Kindle ocupado por outro app" (uma vez por conexão). Como a conexão não foi marcada como sincronizada, o próximo `StartInterval` tenta de novo sozinho (uma tentativa por rodada, para não encher o log).

O que você faz: feche o app (`killall "Android File Transfer" "Android File Transfer Agent"`), desconecte e reconecte o Kindle ou rode `~/.local/bin/kindle-clippings-sync --now`. Se o culpado for o `ptpcamerad`, `KCS_MTP_KILL_PTPCAMERAD=1` encerra o processo antes de tentar de novo (o macOS o reinicia sozinho depois).

## Permissões do macOS (TCC)

O job roda como `/bin/bash` disparado pelo `launchd`, fora do Terminal. Por isso ele não herda as permissões que o Terminal já tem, e o macOS pode bloquear:

- **iCloud Drive** (`~/Library/Mobile Documents`, onde fica o cofre);
- **Volumes removíveis** (`/Volumes/Kindle`, só nos Kindles antigos). O acesso MTP é feito direto pelo USB e, até onde se sabe, não passa por essa permissão.

Sintomas: o Kindle está conectado mas nada acontece, ou o log mostra `Operation not permitted`, `sem permissão para listar` ou `falha ao copiar`.

Como liberar:

1. Abra **Ajustes do Sistema > Privacidade e Segurança**.
2. Se aparecer um pedido de acesso para `bash` ou `kcs-iokit-trigger`, clique em **Permitir**.
3. Se não aparecer pedido e mesmo assim falhar, vá em **Acesso Total ao Disco**, clique em **+**, pressione `Cmd+Shift+G`, digite `/bin/bash` e ative. Alternativa mais restrita: em **Arquivos e Pastas**, ative **Volumes Removíveis** para `bash`, se ele estiver listado.
4. Desconecte e conecte o Kindle de novo.

Observação: dar Acesso Total ao Disco para `/bin/bash` vale para qualquer script bash, não só este. Tente primeiro sem isso; com o Kindle MTP normalmente só o iCloud Drive importa.

Notificações aparecem em nome do **Editor de Scripts** (o `osascript`). Se não aparecerem, confira em **Ajustes do Sistema > Notificações > Editor de Scripts**.

## Diagnóstico

```bash
tail -f ~/Library/Logs/kindle-clippings-sync.log
launchctl print gui/$(id -u)/digital.gabriel.kindle-clippings-sync | head -n 40
ioreg -p IOUSB -l -w0 | grep -E '"(USB Product Name|idVendor|idProduct|sessionID)"'
~/.local/libexec/kindle-clippings-sync/kcs-mtp-pull --list > /tmp/kindle-arvore.tsv   # arvore inteira, 1 sessao
log show --last 10m --predicate 'subsystem == "com.apple.TCC"' | grep -i -E 'bash|kcs'
```

Não use `mtp-detect`, `mtp-folders`, `mtp-files` nem `mtp-getfile` com o Paperwhite: cada um abre uma sessão e, ao fechar, o libmtp reseta o USB e o Kindle some até ser reconectado (veja acima). Para inspecionar o aparelho use o próprio `kcs-mtp-pull`, que faz tudo numa sessão, sem o reset, e só lê:

```bash
P=~/.local/libexec/kindle-clippings-sync/kcs-mtp-pull
$P --list                                    # T id pai storage bytes mtime(epoch) caminho, separados por TAB
$P --get "/system/version.txt" /tmp/v.txt    # baixa pelo caminho completo
$P --get-dir "/documents/Downloads/Items01/<livro>.sdr" /tmp/sdr   # arquivos diretos da pasta
$P --get-id 964 /tmp/x                       # pelo id (os ids mudam a cada conexão; prefira o caminho)
$P --list --get A /tmp/a --get B /tmp/b      # varias operações na mesma sessão
```

Cada arquivo baixado gera uma linha `GOT <id> <bytes> <caminho> -> <destino>`; falhas geram `ERR ...` no stderr e código de saída 1 (2 = sem aparelho ou bloqueado, 64 = uso incorreto).

Notas:

- Sem Kindle conectado, ou com a conexão já sincronizada, o script sai sem escrever nada no log.
- O libmtp pode chamar o 1949:9981 de "Kindle Scribe 32GB" ou dizer que o aparelho é `UNKNOWN in libmtp` e pedir para reportar. É só o nome na tabela interna dele; o acesso funciona como MTP genérico.

## Limitações conhecidas

- O helper do evento de IOKit é compilado no Mac; se as Command Line Tools não estiverem instaladas, o gatilho fica só no `StartInterval` (até 2 min de atraso).
- Se houver dois Kindles conectados ao mesmo tempo, só o primeiro é sincronizado.
- A partir do firmware 5.19.6 (agosto de 2026) o Kindle deixou de acrescentar destaques novos ao `My Clippings.txt` em vários modelos (relatos de Colorsoft, Scribe e, aqui, do Paperwhite 5.20.1). Os destaques continuam no aparelho, em `/system/ksdk/.annotations/<conta>/ksdk_annotation_v1.db` (SQLite, só posições, sem texto). Este projeto ainda sincroniza só o `My Clippings.txt`.
- O download via MTP lê a lista de arquivos do aparelho inteiro; com bibliotecas grandes pode levar alguns segundos.

## Testes

```bash
bash tests/run-tests.sh
bash tests/lint.sh
```

Os testes rodam em Linux ou macOS com um `/Volumes`, um cofre e um `HOME` falsos e com versões falsas de `ioreg`, `kcs-mtp-pull`, `mtp-files`, `mtp-folders`, `mtp-getfile`, `mtp-detect`, `brew` e `osascript` em `tests/fakes/`. As saídas falsas seguem o formato do libmtp 1.1.22 (`examples/files.c`, `folders.c`, `getfile.c` e as mensagens de erro de `src/libusb1-glue.c`) e do `ioreg -p IOUSB -l -w0` de um Mac Apple Silicon. Cobrem, entre outros:

- `/Volumes`: ausência de Kindle, pendrive sem marcador, cópia byte a byte com BOM e CRLF, backup, execução sem mudança, nova entrada, lock, `--force`, config por arquivo, cofre inexistente;
- MTP: uma única sessão por sincronização, disparos simultâneos abrindo uma sessão só, SIGTERM ignorado herdado (timeout continua funcionando), reserva com as ferramentas `mtp-*`, Kindle ausente no `ioreg` (nada de MTP é chamado), escolha da cópia em `documents` entre iscas em outras pastas, reexecução na mesma conexão sem abrir o MTP, reconexão, aparelho ocupado (com e sem recuperação), `No devices.` no `mtp-getfile`, comando travado (timeout), aparelho sem `My Clippings.txt`, libmtp ausente, ferramentas achadas pelo PATH, prioridade do MTP sobre `/Volumes`;
- `kcs-mtp-pull` em C, compilado contra um libmtp falso (`tests/stub-libmtp/`): modo padrão, `--list`, `--get`, `--get-dir`, `--get-id`, várias operações numa sessão só, reset desligado, erros e códigos de saída;
- instalador: plist com e sem helper (`LaunchEvents`, `idVendor`, `idProduct`, `StartInterval`), `--product-id any`, `--interval`, `--no-iokit`, `--install-deps`, reinstalação preservando a config, execução ponta a ponta pelo helper e desinstalação.

`tests/lint.sh` roda o `shellcheck` e valida os plists gerados (`plutil`, `xmllint` ou `python3` com o DTD da Apple, o que existir).

## Licença

MIT. Veja [LICENSE](LICENSE).
