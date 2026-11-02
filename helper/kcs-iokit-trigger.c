/*
 * kcs-iokit-trigger: consome o evento com.apple.iokit.matching entregue pelo
 * launchd e depois executa o comando recebido nos argumentos.
 *
 * Por que existe: um LaunchAgent com LaunchEvents/com.apple.iokit.matching
 * precisa "aceitar" o evento com xpc_set_event_stream_handler(). Se o job sair
 * sem fazer isso, o launchd considera o evento pendente e relanca o job em
 * loop enquanto o aparelho estiver conectado. Um script bash nao consegue
 * chamar essa API, entao este programa minimo faz isso e depois chama
 * execv() no script (o processo vira /bin/bash, sem ficar residente).
 *
 * Se for iniciado sem evento (StartInterval, StartOnMount ou manualmente),
 * espera ~1 s e executa o comando do mesmo jeito.
 *
 * Compilar: cc -O2 -Wall -o kcs-iokit-trigger kcs-iokit-trigger.c
 * Uso:      kcs-iokit-trigger /bin/bash /caminho/kindle-clippings-sync
 */
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static char **g_cmd = NULL;

/*
 * O libdispatch/XPC deixa sinais ignorados ou bloqueados neste processo, e o
 * execv() herda isso. Sem esta limpeza o bash recebia SIGTERM ignorado ("sinais
 * ignorados na entrada nao podem ser capturados"), entao nem o timeout do
 * script nem um kill comum conseguiam encerrar os processos filhos.
 */
static void reset_signals(void) {
    sigset_t empty;
    int sig;
    for (sig = 1; sig < NSIG; sig++) {
        if (sig == SIGKILL || sig == SIGSTOP) {
            continue;
        }
        signal(sig, SIG_DFL);
    }
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);
}

static void run_command(void) {
    if (g_cmd == NULL || g_cmd[0] == NULL) {
        exit(0);
    }
    reset_signals();
    execv(g_cmd[0], g_cmd);
    perror("kcs-iokit-trigger: execv");
    exit(127);
}

int main(int argc, char **argv) {
    if (argc > 1) {
        g_cmd = &argv[1];
    }

    xpc_set_event_stream_handler("com.apple.iokit.matching", dispatch_get_main_queue(),
        ^(xpc_object_t event) {
            const char *name = xpc_dictionary_get_string(event, XPC_EVENT_KEY_NAME);
            fprintf(stderr, "kcs-iokit-trigger: evento IOKit recebido (%s)\n",
                    name ? name : "?");
        });

    /* Da tempo para o launchd entregar o(s) evento(s) pendente(s) e segue. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       run_command();
                   });

    dispatch_main();
    return 0;
}
