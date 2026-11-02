/*
 * kcs-mtp-pull: baixa documents/My Clippings.txt de um Kindle MTP numa unica
 * sessao do libmtp.
 *
 * Por que existe: o libmtp 1.1.23 cadastra o 1949:9981 (Kindle Paperwhite,
 * que ele chama de "Kindle Scribe 32GB") com DEVICE_FLAGS_ANDROID_BUGS, que
 * inclui DEVICE_FLAG_FORCE_RESET_ON_CLOSE. Ao fechar cada sessao o libmtp
 * chama libusb_reset_device() e o Kindle cai do USB. As ferramentas mtp-files,
 * mtp-folders e mtp-getfile abrem uma sessao cada, entao a segunda ja nao
 * encontra o aparelho. Aqui abrimos o aparelho uma vez, desligamos esse flag
 * antes de abrir, listamos so a raiz e a pasta documents, baixamos e liberamos.
 *
 * Uso: kcs-mtp-pull [--allow-reset] [--no-release-interface] <arquivo-destino>
 *      kcs-mtp-pull [opcoes] --list [--get CAMINHO DEST]... [--get-id ID DEST]...
 *                   [--get-dir CAMINHO DIR-DEST]...
 *   Modo inventario (somente leitura, tudo numa sessao):
 *   --list                  imprime a arvore inteira, uma linha por item, TAB:
 *                           T <id> <pai> <storage> <bytes> <mtime-epoch> <caminho>
 *                           (T = d pasta, f arquivo)
 *   --get CAMINHO DEST      baixa o arquivo de caminho absoluto no aparelho
 *   --get-id ID DEST        baixa pelo item id (ids mudam entre sessoes!)
 *   --get-dir CAMINHO DIR   baixa todos os arquivos diretamente dentro da pasta
 *   Cada download imprime: GOT <id> <bytes> <caminho> -> <dest>
 *   Falhas imprimem ERR ... em stderr e o codigo de saida vira 1.
 *   --allow-reset           mantem o reset ao fechar (comportamento padrao do libmtp)
 *   --no-release-interface  nao libera a interface USB ao fechar
 *                           (DEVICE_FLAG_NO_RELEASE_INTERFACE), para aparelhos
 *                           que caem do USB mesmo sem o reset
 *
 * Saida (stdout), em sucesso:  OK <item-id> <bytes> <caminho no aparelho>
 * Codigos de saida:
 *   0 ok
 *   1 erro de download ou de escrita
 *   2 nenhum aparelho / aparelho ocupado / falha ao abrir
 *   3 My Clippings.txt nao existe no aparelho
 *   64 uso incorreto
 *
 * Compilar: xcrun clang -O2 -Wall -o kcs-mtp-pull kcs-mtp-pull.c \
 *             $(pkg-config --cflags --libs libmtp)
 */
#include <libmtp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#define KCS_AMAZON_VID 0x1949
#define KCS_FLAG_FORCE_RESET_ON_CLOSE 0x10000000u /* src/device-flags.h */
#define KCS_FLAG_NO_RELEASE_INTERFACE 0x00000040u /* src/device-flags.h */
#define KCS_CLIPPINGS "My Clippings.txt"
#define KCS_MAX_DEPTH 4

typedef struct {
    uint32_t id;
    uint32_t storage;
    uint64_t size;
    int score; /* 3 = /documents, 2 = .../documents, 1 = outro lugar */
    char where[512];
} candidate_t;

static int is_folder(const LIBMTP_file_t *f) {
    return f->filetype == LIBMTP_FILETYPE_FOLDER;
}

static void consider(candidate_t *best, const LIBMTP_file_t *f, int score,
                     const char *path) {
    if (score > best->score) {
        best->id = f->item_id;
        best->storage = f->storage_id;
        best->size = f->filesize;
        best->score = score;
        snprintf(best->where, sizeof(best->where), "%s/%s", path, f->filename);
    }
}

/* Busca recursiva (reserva, so se nao houver /documents na raiz). */
static void search(LIBMTP_mtpdevice_t *dev, uint32_t storage, uint32_t parent,
                   const char *parent_name, const char *path, int depth,
                   candidate_t *best) {
    LIBMTP_file_t *files, *f, *next;
    if (depth > KCS_MAX_DEPTH) {
        return;
    }
    files = LIBMTP_Get_Files_And_Folders(dev, storage, parent);
    for (f = files; f != NULL; f = next) {
        next = f->next;
        if (f->filename != NULL) {
            if (is_folder(f)) {
                char sub[512];
                snprintf(sub, sizeof(sub), "%s/%s", path, f->filename);
                search(dev, storage, f->item_id, f->filename, sub, depth + 1, best);
            } else if (strcasecmp(f->filename, KCS_CLIPPINGS) == 0) {
                int in_docs = parent_name != NULL && strcasecmp(parent_name, "documents") == 0;
                consider(best, f, in_docs ? (depth == 2 ? 3 : 2) : 1, path);
            }
        }
        LIBMTP_destroy_file_t(f);
    }
}

/* ---------- modo inventario ---------- */
typedef struct {
    uint32_t id, parent, storage;
    uint64_t size;
    long mtime;
    int folder;
    char *path;
} node_t;

static node_t *nodes = NULL;
static size_t nnodes = 0, capnodes = 0;

static void walk(LIBMTP_mtpdevice_t *dev, uint32_t storage, uint32_t parent,
                 const char *path, int depth) {
    LIBMTP_file_t *files, *f, *next;
    if (depth > 16) {
        return;
    }
    files = LIBMTP_Get_Files_And_Folders(dev, storage, parent);
    for (f = files; f != NULL; f = next) {
        next = f->next;
        if (f->filename != NULL) {
            size_t len = strlen(path) + strlen(f->filename) + 2;
            node_t *n;
            if (nnodes == capnodes) {
                capnodes = capnodes ? capnodes * 2 : 256;
                nodes = realloc(nodes, capnodes * sizeof(node_t));
                if (nodes == NULL) {
                    exit(1);
                }
            }
            n = &nodes[nnodes++];
            n->id = f->item_id;
            n->parent = f->parent_id;
            n->storage = f->storage_id;
            n->size = f->filesize;
            n->mtime = (long)f->modificationdate;
            n->folder = is_folder(f);
            n->path = malloc(len);
            if (n->path == NULL) {
                exit(1);
            }
            snprintf(n->path, len, "%s/%s", path, f->filename);
            if (n->folder) {
                char *sub = strdup(n->path); /* nodes pode ser realocado */
                uint32_t id = f->item_id;
                walk(dev, storage, id, sub, depth + 1);
                free(sub);
            }
        }
        LIBMTP_destroy_file_t(f);
    }
}

static int fetch(LIBMTP_mtpdevice_t *dev, const node_t *n, const char *dest) {
    struct stat sb;
    if (n->folder) {
        fprintf(stderr, "ERR pasta, nao arquivo: %s\n", n->path);
        return 1;
    }
    if (LIBMTP_Get_File_To_File(dev, n->id, dest, NULL, NULL) != 0) {
        fprintf(stderr, "ERR download %u %s\n", n->id, n->path);
        LIBMTP_Dump_Errorstack(dev);
        LIBMTP_Clear_Errorstack(dev);
        return 1;
    }
    if (stat(dest, &sb) != 0 || (uint64_t)sb.st_size != n->size) {
        fprintf(stderr, "ERR tamanho %s (esperado %llu)\n", n->path, (unsigned long long)n->size);
        return 1;
    }
    printf("GOT %u %llu %s -> %s\n", n->id, (unsigned long long)n->size, n->path, dest);
    return 0;
}

static int inventory(LIBMTP_mtpdevice_t *dev, int argc, char **argv, int list) {
    LIBMTP_devicestorage_t *st;
    size_t k;
    int i, rc = 0;
    for (st = dev->storage; st != NULL; st = st->next) {
        walk(dev, st->id, LIBMTP_FILES_AND_FOLDERS_ROOT, "", 1);
    }
    if (list) {
        for (k = 0; k < nnodes; k++) {
            printf("%c\t%u\t%u\t%u\t%llu\t%ld\t%s\n", nodes[k].folder ? 'd' : 'f',
                   nodes[k].id, nodes[k].parent, nodes[k].storage,
                   (unsigned long long)nodes[k].size, nodes[k].mtime, nodes[k].path);
        }
        fflush(stdout);
    }
    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--get") == 0 || strcmp(a, "--get-id") == 0 ||
            strcmp(a, "--get-dir") == 0) {
            const char *key = argv[i + 1], *dest = argv[i + 2];
            int found = 0;
            i += 2;
            for (k = 0; k < nnodes; k++) {
                node_t *n = &nodes[k];
                if (strcmp(a, "--get") == 0 && strcmp(n->path, key) == 0) {
                    rc |= fetch(dev, n, dest);
                    found = 1;
                    break;
                } else if (strcmp(a, "--get-id") == 0 && n->id == (uint32_t)strtoul(key, NULL, 10)) {
                    rc |= fetch(dev, n, dest);
                    found = 1;
                    break;
                } else if (strcmp(a, "--get-dir") == 0 && !n->folder) {
                    size_t kl = strlen(key);
                    const char *base = strrchr(n->path, '/');
                    if (strncmp(n->path, key, kl) == 0 && n->path[kl] == '/' &&
                        base == n->path + kl) {
                        char out[1024];
                        snprintf(out, sizeof(out), "%s/%s", dest, base + 1);
                        rc |= fetch(dev, n, out);
                        found = 1;
                    }
                }
            }
            if (!found) {
                fprintf(stderr, "ERR nao encontrado: %s\n", key);
                rc = 1;
            }
        }
    }
    return rc;
}

int main(int argc, char **argv) {
    LIBMTP_raw_device_t *raw = NULL;
    LIBMTP_mtpdevice_t *dev;
    LIBMTP_devicestorage_t *st;
    LIBMTP_error_number_t err;
    candidate_t best;
    const char *dest = NULL;
    int allow_reset = 0, no_release = 0, nraw = 0, pick = 0, i, rc = 3;
    int inv_mode = 0, list = 0;
    struct stat sb;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--allow-reset") == 0) {
            allow_reset = 1;
        } else if (strcmp(argv[i], "--no-release-interface") == 0) {
            no_release = 1;
        } else if (strcmp(argv[i], "--list") == 0) {
            inv_mode = list = 1;
        } else if (strcmp(argv[i], "--get") == 0 || strcmp(argv[i], "--get-id") == 0 ||
                   strcmp(argv[i], "--get-dir") == 0) {
            if (i + 2 >= argc) {
                fprintf(stderr, "uso: %s exige 2 argumentos\n", argv[i]);
                return 64;
            }
            inv_mode = 1;
            i += 2;
        } else if (dest == NULL) {
            dest = argv[i];
        } else {
            dest = NULL;
            break;
        }
    }
    if (dest == NULL && !inv_mode) {
        fprintf(stderr, "uso: kcs-mtp-pull [--allow-reset] [--no-release-interface] <arquivo-destino>\n");
        return 64;
    }

    LIBMTP_Init();
    err = LIBMTP_Detect_Raw_Devices(&raw, &nraw);
    if (err == LIBMTP_ERROR_NO_DEVICE_ATTACHED || nraw == 0) {
        fprintf(stderr, "kcs-mtp-pull: No raw devices found.\n");
        return 2;
    }
    if (err != LIBMTP_ERROR_NONE) {
        fprintf(stderr, "kcs-mtp-pull: error connecting (%d)\n", (int)err);
        return 2;
    }

    /* Prefere um aparelho Amazon, se houver mais de um. */
    for (i = 0; i < nraw; i++) {
        if (raw[i].device_entry.vendor_id == KCS_AMAZON_VID) {
            pick = i;
            break;
        }
    }
    fprintf(stderr, "kcs-mtp-pull: device %04x:%04x flags 0x%08x\n",
            raw[pick].device_entry.vendor_id, raw[pick].device_entry.product_id,
            raw[pick].device_entry.device_flags);
    if (!allow_reset) {
        raw[pick].device_entry.device_flags &= ~KCS_FLAG_FORCE_RESET_ON_CLOSE;
    }
    if (no_release) {
        raw[pick].device_entry.device_flags |= KCS_FLAG_NO_RELEASE_INTERFACE;
    }
    fprintf(stderr, "kcs-mtp-pull: flags usados 0x%08x\n", raw[pick].device_entry.device_flags);

    dev = LIBMTP_Open_Raw_Device_Uncached(&raw[pick]);
    if (dev == NULL) {
        fprintf(stderr, "Unable to open raw device %d\n", pick);
        free(raw);
        return 2;
    }
    LIBMTP_Clear_Errorstack(dev);

    memset(&best, 0, sizeof(best));
    if (LIBMTP_Get_Storage(dev, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0 || dev->storage == NULL) {
        fprintf(stderr, "kcs-mtp-pull: no storage (device locked?)\n");
        LIBMTP_Dump_Errorstack(dev);
        LIBMTP_Release_Device(dev);
        free(raw);
        return 2;
    }

    if (inv_mode) {
        rc = inventory(dev, argc, argv, list);
        LIBMTP_Release_Device(dev);
        free(raw);
        return rc;
    }

    /* 1) Caminho rapido: /documents na raiz de cada armazenamento. */
    for (st = dev->storage; st != NULL && best.score < 3; st = st->next) {
        LIBMTP_file_t *root = LIBMTP_Get_Files_And_Folders(dev, st->id, LIBMTP_FILES_AND_FOLDERS_ROOT);
        LIBMTP_file_t *f, *next;
        for (f = root; f != NULL; f = next) {
            next = f->next;
            if (best.score < 3 && is_folder(f) && f->filename != NULL &&
                strcasecmp(f->filename, "documents") == 0) {
                LIBMTP_file_t *docs = LIBMTP_Get_Files_And_Folders(dev, st->id, f->item_id);
                LIBMTP_file_t *g, *gn;
                for (g = docs; g != NULL; g = gn) {
                    gn = g->next;
                    if (!is_folder(g) && g->filename != NULL &&
                        strcasecmp(g->filename, KCS_CLIPPINGS) == 0) {
                        consider(&best, g, 3, "/documents");
                    }
                    LIBMTP_destroy_file_t(g);
                }
            }
            LIBMTP_destroy_file_t(f);
        }
    }
    /* 2) Reserva: busca limitada em todo o aparelho. */
    for (st = dev->storage; st != NULL && best.score == 0; st = st->next) {
        search(dev, st->id, LIBMTP_FILES_AND_FOLDERS_ROOT, NULL, "", 1, &best);
    }

    if (best.score == 0) {
        fprintf(stderr, "kcs-mtp-pull: %s not found\n", KCS_CLIPPINGS);
        rc = 3;
    } else if (LIBMTP_Get_File_To_File(dev, best.id, dest, NULL, NULL) != 0) {
        fprintf(stderr, "Error getting file from MTP device.\n");
        LIBMTP_Dump_Errorstack(dev);
        LIBMTP_Clear_Errorstack(dev);
        rc = 1;
    } else if (stat(dest, &sb) != 0 || (uint64_t)sb.st_size != best.size) {
        fprintf(stderr, "kcs-mtp-pull: size mismatch (expected %llu)\n",
                (unsigned long long)best.size);
        rc = 1;
    } else {
        printf("OK %u %llu %s\n", best.id, (unsigned long long)best.size, best.where);
        rc = 0;
    }

    LIBMTP_Release_Device(dev);
    free(raw);
    return rc;
}
