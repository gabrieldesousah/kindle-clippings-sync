/*
 * libmtp.h falso, so para os testes: declara o subconjunto da API do libmtp
 * que o kcs-mtp-pull usa. A implementacao (libmtp-stub.c) simula um Kindle com
 * uma arvore fixa de arquivos, sem USB. Nao e o libmtp de verdade.
 */
#ifndef KCS_LIBMTP_STUB_H
#define KCS_LIBMTP_STUB_H
#include <stdint.h>
#include <time.h>

typedef enum {
    LIBMTP_ERROR_NONE = 0,
    LIBMTP_ERROR_GENERAL = 1,
    LIBMTP_ERROR_NO_DEVICE_ATTACHED = 5
} LIBMTP_error_number_t;

typedef enum { LIBMTP_FILETYPE_FOLDER = 0, LIBMTP_FILETYPE_UNKNOWN = 44 } LIBMTP_filetype_t;

#define LIBMTP_FILES_AND_FOLDERS_ROOT 0xffffffffu
#define LIBMTP_STORAGE_SORTBY_NOTSORTED 0

typedef struct {
    char *vendor;
    uint16_t vendor_id;
    char *product;
    uint16_t product_id;
    uint32_t device_flags;
} LIBMTP_device_entry_t;

typedef struct {
    LIBMTP_device_entry_t device_entry;
    uint32_t bus_location;
    uint8_t devnum;
} LIBMTP_raw_device_t;

typedef struct LIBMTP_devicestorage_struct {
    uint32_t id;
    struct LIBMTP_devicestorage_struct *next;
} LIBMTP_devicestorage_t;

typedef struct {
    LIBMTP_devicestorage_t *storage;
} LIBMTP_mtpdevice_t;

typedef struct LIBMTP_file_struct {
    uint32_t item_id;
    uint32_t parent_id;
    uint32_t storage_id;
    char *filename;
    uint64_t filesize;
    time_t modificationdate;
    LIBMTP_filetype_t filetype;
    struct LIBMTP_file_struct *next;
} LIBMTP_file_t;

typedef int (*LIBMTP_progressfunc_t)(uint64_t, uint64_t, void const *const);

void LIBMTP_Init(void);
LIBMTP_error_number_t LIBMTP_Detect_Raw_Devices(LIBMTP_raw_device_t **, int *);
LIBMTP_mtpdevice_t *LIBMTP_Open_Raw_Device_Uncached(LIBMTP_raw_device_t *);
void LIBMTP_Release_Device(LIBMTP_mtpdevice_t *);
void LIBMTP_Clear_Errorstack(LIBMTP_mtpdevice_t *);
void LIBMTP_Dump_Errorstack(LIBMTP_mtpdevice_t *);
int LIBMTP_Get_Storage(LIBMTP_mtpdevice_t *, int const);
LIBMTP_file_t *LIBMTP_Get_Files_And_Folders(LIBMTP_mtpdevice_t *, uint32_t const, uint32_t const);
void LIBMTP_destroy_file_t(LIBMTP_file_t *);
int LIBMTP_Get_File_To_File(LIBMTP_mtpdevice_t *, uint32_t const, char const *const,
                            LIBMTP_progressfunc_t const, void const *const);
#endif
