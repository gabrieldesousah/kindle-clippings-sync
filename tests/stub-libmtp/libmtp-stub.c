/*
 * Implementacao falsa do libmtp para testar o kcs-mtp-pull sem aparelho.
 * Arvore fixa (parecida com a de um Paperwhite 5.20). O conteudo de cada
 * arquivo e "item <id>\n" repetido ate o tamanho. Variaveis:
 *   STUB_MODE=nodevice | nostorage | failget   simula falhas
 *   STUB_LOG=<arquivo>                          registra open/list/get/release
 */
#include "libmtp.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint32_t id, parent; int folder; const char *name; uint64_t size; } ent_t;

static const ent_t tree[] = {
    {1, LIBMTP_FILES_AND_FOLDERS_ROOT, 1, "documents", 0},
    {10, 1, 0, "My Clippings.txt", 40},
    {11, 1, 1, "My Clippings.sdr", 0},
    {12, 11, 0, "My Clippingsabc.mbp1", 9},
    {20, 1, 1, "Downloads", 0},
    {21, 20, 1, "Items01", 0},
    {22, 21, 0, "Livro Com\xc3\xa7o_ID1.kfx", 100},
    {23, 21, 1, "Livro Com\xc3\xa7o_ID1.sdr", 0},
    {24, 23, 0, "Livro_ID1abc.yjr", 21},
    {25, 23, 0, "Livro_ID1abc.yjf", 33},
    {26, 23, 1, "assets", 0},
    {27, 26, 0, "inner.bin", 5},
    {2, LIBMTP_FILES_AND_FOLDERS_ROOT, 1, "system", 0},
    {30, 2, 0, "version.txt", 30},
    {31, 2, 1, "ksdk", 0},
    {32, 31, 1, ".annotations", 0},
    {33, 32, 1, "amzn1.account.TESTE", 0},
    {34, 33, 0, "ksdk_annotation_v1.db", 64},
    {35, 32, 1, "anonymous", 0},
    {36, 35, 0, "ksdk_annotation_v1.db", 16},
};
#define NTREE (sizeof(tree) / sizeof(tree[0]))

static LIBMTP_devicestorage_t storage = {0x10001, NULL};
static LIBMTP_mtpdevice_t device = {NULL};

static const char *mode(void) {
    const char *m = getenv("STUB_MODE");
    return m ? m : "";
}

static void logf_(const char *fmt, unsigned v) {
    const char *p = getenv("STUB_LOG");
    FILE *f;
    if (p == NULL || (f = fopen(p, "a")) == NULL) {
        return;
    }
    fprintf(f, fmt, v);
    fputc('\n', f);
    fclose(f);
}

void LIBMTP_Init(void) {}

LIBMTP_error_number_t LIBMTP_Detect_Raw_Devices(LIBMTP_raw_device_t **out, int *n) {
    LIBMTP_raw_device_t *r;
    if (strcmp(mode(), "nodevice") == 0) {
        *n = 0;
        return LIBMTP_ERROR_NO_DEVICE_ATTACHED;
    }
    r = calloc(1, sizeof(*r));
    r->device_entry.vendor_id = 0x1949;
    r->device_entry.product_id = 0x9981;
    r->device_entry.device_flags = 0x18008106u;
    *out = r;
    *n = 1;
    return LIBMTP_ERROR_NONE;
}

LIBMTP_mtpdevice_t *LIBMTP_Open_Raw_Device_Uncached(LIBMTP_raw_device_t *r) {
    logf_("open 0x%08x", r->device_entry.device_flags);
    return &device;
}

void LIBMTP_Release_Device(LIBMTP_mtpdevice_t *d) {
    (void)d;
    logf_("release %u", 0);
}

void LIBMTP_Clear_Errorstack(LIBMTP_mtpdevice_t *d) { (void)d; }
void LIBMTP_Dump_Errorstack(LIBMTP_mtpdevice_t *d) { (void)d; }

int LIBMTP_Get_Storage(LIBMTP_mtpdevice_t *d, int const s) {
    (void)s;
    if (strcmp(mode(), "nostorage") == 0) {
        d->storage = NULL;
        return 1;
    }
    d->storage = &storage;
    return 0;
}

LIBMTP_file_t *LIBMTP_Get_Files_And_Folders(LIBMTP_mtpdevice_t *d, uint32_t const st, uint32_t const parent) {
    LIBMTP_file_t *head = NULL, **tail = &head;
    size_t i;
    (void)d;
    logf_("list %u", parent);
    for (i = 0; i < NTREE; i++) {
        if (tree[i].parent == parent) {
            LIBMTP_file_t *f = calloc(1, sizeof(*f));
            f->item_id = tree[i].id;
            f->parent_id = parent == LIBMTP_FILES_AND_FOLDERS_ROOT ? 0 : parent;
            f->storage_id = st;
            f->filename = strdup(tree[i].name);
            f->filesize = tree[i].size;
            f->modificationdate = (time_t)(1790000000 + tree[i].id);
            f->filetype = tree[i].folder ? LIBMTP_FILETYPE_FOLDER : LIBMTP_FILETYPE_UNKNOWN;
            *tail = f;
            tail = &f->next;
        }
    }
    return head;
}

void LIBMTP_destroy_file_t(LIBMTP_file_t *f) {
    if (f != NULL) {
        free(f->filename);
        free(f);
    }
}

int LIBMTP_Get_File_To_File(LIBMTP_mtpdevice_t *d, uint32_t const id, char const *const path,
                            LIBMTP_progressfunc_t const cb, void const *const data) {
    size_t i;
    (void)d;
    (void)cb;
    (void)data;
    logf_("get %u", id);
    if (strcmp(mode(), "failget") == 0) {
        return 1;
    }
    for (i = 0; i < NTREE; i++) {
        if (tree[i].id == id && !tree[i].folder) {
            char chunk[32];
            uint64_t w = 0;
            FILE *f = fopen(path, "wb");
            if (f == NULL) {
                return 1;
            }
            snprintf(chunk, sizeof(chunk), "item %u\n", id);
            while (w < tree[i].size) {
                fputc(chunk[w % strlen(chunk)], f);
                w++;
            }
            fclose(f);
            return 0;
        }
    }
    return 1;
}
