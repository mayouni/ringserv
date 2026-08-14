/*
** RingServ — native companion C for the bridge. Ported from RingScript's
** wasi_stubs.c with the WASI parts removed and the file layer opened up:
** where the browser runtime resolves EVERY file access against the
** embedded map (there is no filesystem there), the server resolves the
** embedded ringlib first and then falls through to the real filesystem —
** a server has one, and `load "app.ring"` must reach it.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include "ring.h"

/*
** Every fopen/stat in the vendored VM is redirected here at compile time
** (-Dfopen=rs_fopen / -Dstat(a,b)=rs_stat(a,b) in build.zig — this file is
** compiled WITHOUT those flags, so the real libc calls below are real).
**
** fmemopen does not exist on Windows, so the embedded bytes are served
** through an unnamed temp file instead: created, filled, rewound, and — by
** tmpfile()'s contract — deleted automatically on fclose. The VM reads a
** perfectly ordinary FILE*.
*/
extern const unsigned char *rs_find_embedded(const char *cPath, size_t *pLen);

/*
** tmpfile() is unusable on Windows: it creates in the drive root, which is
** access-denied for ordinary users. UCRT's fopen accepts the "D" mode flag
** (delete on last close), which with _tempnam gives the same
** anonymous-temporary contract portably enough for this use.
*/
static FILE *rs_tmpfile(void) {
#ifdef _WIN32
	char *cName = _tempnam(NULL, "ringserv");
	FILE *pFile;
	if (cName == NULL) {
		return NULL;
	}
	pFile = fopen(cName, "w+bD");
	if (pFile == NULL) {
		pFile = fopen(cName, "w+b");
	}
	free(cName);
	return pFile;
#else
	return tmpfile();
#endif
}

FILE *rs_fopen(const char *cPath, const char *cMode) {
	size_t nLen;
	const unsigned char *pData;
	FILE *pFile;
	if (cMode != NULL && cMode[0] == 'r') {
		pData = rs_find_embedded(cPath, &nLen);
		if (pData != NULL) {
			pFile = rs_tmpfile();
			if (pFile == NULL) {
				return NULL;
			}
			if (nLen > 0 && fwrite(pData, 1, nLen, pFile) != nLen) {
				fclose(pFile);
				return NULL;
			}
			rewind(pFile);
			return pFile;
		}
	}
	return fopen(cPath, cMode);
}

int rs_stat(const char *cPath, struct stat *pBuf) {
	size_t nLen;
	const unsigned char *pData;
	if (pBuf == NULL) {
		errno = EFAULT;
		return -1;
	}
	pData = rs_find_embedded(cPath, &nLen);
	if (pData != NULL) {
		memset(pBuf, 0, sizeof(*pBuf));
		pBuf->st_mode = S_IFREG | 0444;
		pBuf->st_size = (off_t)nLen;
		pBuf->st_nlink = 1;
		return 0;
	}
	return stat(cPath, pBuf);
}

/*
** CLI echo: stream bridge output to stdout as it is produced. Deliberately
** here, not in Zig — this file shares the one libc stdio FILE* buffer with
** the VM's own C-level output (print(), puts()), so interleaving between
** hook-captured `see` output and direct C output stays in true order.
*/
void rs_echo_write(const unsigned char *pData, size_t nLen) {
	fwrite(pData, 1, nLen, stdout);
}

/*
** List accessors as real functions. Ring exposes these as MACROS
** (rlist.h), which Zig cannot link against, so db.zig calls these thin
** wrappers instead. Same semantics, one call deep.
*/
int rs_list_getsize(List *pList) {
	return (int)ring_list_getsize(pList);
}

int rs_list_isstring(List *pList, int nIndex) {
	return ring_list_isstring(pList, nIndex);
}

const char *rs_list_getstring(List *pList, int nIndex) {
	return ring_list_getstring(pList, nIndex);
}

int rs_list_getstringsize(List *pList, int nIndex) {
	return (int)ring_list_getstringsize(pList, nIndex);
}

int rs_list_isnumber(List *pList, int nIndex) {
	return ring_list_isnumber(pList, nIndex);
}

double rs_list_getdouble(List *pList, int nIndex) {
	return ring_list_getdouble(pList, nIndex);
}

/* 1 if the VM already auto-called main() (lCallMainFunction is a bitfield —
** not addressable from Zig). */
unsigned int rs_vm_maincalled(void *pPointer) {
	VM *pVM = (VM *)pPointer;
	return pVM->lCallMainFunction;
}

/* Current decimals() setting (nDecimals is a bitfield). The bridge formats
** see-hook numbers through the VM's own ring_general_numtostring with this,
** matching native output exactly. */
unsigned int rs_vm_decimals(void *pPointer) {
	VM *pVM = (VM *)pPointer;
	return pVM->nDecimals;
}

/*
** Value printers for the see hook — exact mirrors of the vendor printers
** (ring_list_print2_gc / ring_list_printobj_gc in rlist.c) but writing into
** the bridge output buffer instead of stdout. Identical to RingScript's,
** and held that way: a divergence here is an output-oracle failure.
*/
extern void rs_append_output(const unsigned char *pData, size_t nLen);

static void rs_out_cstr(const char *cStr) {
	rs_append_output((const unsigned char *)cStr, strlen(cStr));
}

static void rs_out_number(void *pPointer, double nNum) {
	char cStr[RING_MEDIUMBUF + 8];
	ring_general_numtostring(nNum, cStr, ((VM *)pPointer)->nDecimals);
	rs_out_cstr(cStr);
}

void rs_print_list(void *pPointer, List *pList);

void rs_print_obj(void *pPointer, List *pList) {
	List *pList2, *pList3;
	unsigned int x;
	pList = RING_OBJECT_GETOBJECTDATA(pList);
	for (x = 3; x <= ring_list_getsize(pList); x++) {
		pList2 = ring_list_getlist(pList, x);
		rs_out_cstr(RING_VAR_GETNAME(pList2));
		rs_out_cstr(": ");
		if (RING_VAR_ISSTRING(pList2)) {
			rs_append_output((const unsigned char *)RING_VAR_GETSTRING(pList2),
					 RING_VAR_GETSTRINGSIZE(pList2));
			rs_out_cstr("\n");
		} else if (RING_VAR_ISNUMBER(pList2)) {
			rs_out_number(pPointer, RING_VAR_GETNUMBER(pList2));
			rs_out_cstr("\n");
		} else if (RING_VAR_ISLIST(pList2)) {
			pList3 = RING_VAR_GETLIST(pList2);
			if (ring_list_isobject(pList3)) {
				rs_out_cstr("Object...\n");
			} else {
				rs_out_cstr("[This Attribute Contains A List]\n");
			}
		}
	}
}

void rs_print_list(void *pPointer, List *pList) {
	unsigned int x;
	double y;
	List *pList2;
	char cStr[RING_MEDIUMBUF];
	for (x = 1; x <= ring_list_getsize(pList); x++) {
		if (ring_list_isstring(pList, x)) {
			rs_append_output((const unsigned char *)ring_list_getstring(pList, x),
					 ring_list_getstringsize(pList, x));
			rs_out_cstr("\n");
		} else if (ring_list_isnumber(pList, x)) {
			if (ring_list_isdouble(pList, x)) {
				y = ring_list_getdouble(pList, x);
				if (y == (int)y) {
					sprintf(cStr, "%.0f", y);
					rs_out_cstr(cStr);
					rs_out_cstr("\n");
				} else {
					rs_out_number(pPointer, y);
					rs_out_cstr("\n");
				}
			} else if (ring_list_isint(pList, x)) {
				sprintf(cStr, "%d", ring_list_getint(pList, x));
				rs_out_cstr(cStr);
				rs_out_cstr("\n");
			}
		} else if (ring_list_islist(pList, x)) {
			pList2 = ring_list_getlist(pList, x);
			if (ring_list_isobject(pList2)) {
				rs_print_obj(pPointer, pList2);
			} else if (ring_list_isref_gc(NULL, pList2)) {
				sprintf(cStr, "[...] (RC:%d)\n", ring_list_getrefcount_gc(NULL, pList2));
				rs_out_cstr(cStr);
			} else {
				rs_print_list(pPointer, pList2);
			}
		} else if (ring_list_ispointer(pList, x)) {
			sprintf(cStr, "%p\n", ring_list_getpointer(pList, x));
			rs_out_cstr(cStr);
		} else if (ring_list_isfuncpointer(pList, x)) {
			sprintf(cStr, "%p\n", ring_list_getfuncpointer(pList, x));
			rs_out_cstr(cStr);
		}
	}
}

/* see-hook dispatcher for list-or-object values */
void rs_print_value_list(void *pPointer, List *pList) {
	if (ring_list_isobject(pList)) {
		rs_print_obj(pPointer, pList);
	} else {
		rs_print_list(pPointer, pList);
	}
}

/* see of a raw pointer value */
void rs_print_pointer(void *pPointer, void *pValue) {
	char cStr[64];
	sprintf(cStr, "%p", pValue);
	rs_out_cstr(cStr);
}
