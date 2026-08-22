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
** The load anchor (src/rs_path.c): a relative path the VM hands us is
** relative to the file that named it, not to the process. The embedded map is
** still probed with the path AS WRITTEN — `load "ringlib/json.ring"` names a
** baked-in file, not one on disk — and only the fall-through to the real
** filesystem is resolved.
*/
extern const char *rs_path_resolve(const char *cPath, char *cOut, int nOut);
#define RS_STUB_PATHSIZE 8192

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


/*
** ─────────────────────────────────────────────────────────────────────
** THE LIBRARY SEARCH ROOT — found, never carried.
**
** RINGSERV-LOADROOT-01, ruled DEPEND on 2026-08-20: a general Ring
** application server MAY require a Ring installation to be present and
** NEED NOT carry its own search root.
**
** So RingServ ships no Ring library and looks for an installed one:
**
**   1. RINGSERV_RING_HOME, if set — the explicit answer, and the only one
**      an operator can rely on in a container where PATH is minimal;
**   2. otherwise `ring` on PATH, whose parent directory is the home
**      (a Ring installation puts its binary in <home>/bin/).
**
** Found once and cached: this is asked on every failed open of a bare
** name, and walking PATH each time would put a directory scan on the
** load path of every library a program touches.
**
** WHAT THIS BUYS, AND WHAT IT DOES NOT — both halves, because Central's
** routing memo once said "makes every one of them resolve" and the desk
** found that was one half:
**
**   it buys   every Ring LIBRARY resolving — stdlib.ring, jsonlib.ring,
**             and the whole graph each pulls in;
**   it does   NOT make Ring's bundled stdlib.ring RUN, because that graph
**             ends at `loadlib`, and dll_e.c is deliberately absent from
**             build.zig (RING_NODLL). A static binary that cannot load a
**             native extension is a considered property, not an oversight.
**
** Anything that reports this feature must report both. docs/LOADING.md does.
** ─────────────────────────────────────────────────────────────────────
*/

#define RS_HOME_UNSET 0
#define RS_HOME_NONE 1
#define RS_HOME_FOUND 2

static int g_home_state = RS_HOME_UNSET;
static char g_home[RS_STUB_PATHSIZE];

/* Does <cDir>/bin/ring(.exe) exist? The check that makes a directory a
** Ring home rather than merely a directory. */
static int rs_home_looks_right(const char *cDir) {
	char cProbe[RS_STUB_PATHSIZE];
	struct stat st;
	int n;
#ifdef _WIN32
	n = snprintf(cProbe, sizeof(cProbe), "%s/bin/ring.exe", cDir);
#else
	n = snprintf(cProbe, sizeof(cProbe), "%s/bin/ring", cDir);
#endif
	if (n <= 0 || (size_t)n >= sizeof(cProbe)) {
		return 0;
	}
	return stat(cProbe, &st) == 0;
}

/* The directory containing `ring` on PATH, minus the trailing /bin. */
static int rs_home_from_path(char *cOut, size_t nOut) {
	const char *cPath = getenv("PATH");
	const char *p, *q;
	char cDir[RS_STUB_PATHSIZE];
	char cProbe[RS_STUB_PATHSIZE];
	struct stat st;
	size_t nLen;
	int n;
#ifdef _WIN32
	const char cSep = ';';
	const char *cExe = "ring.exe";
#else
	const char cSep = ':';
	const char *cExe = "ring";
#endif
	if (cPath == NULL) {
		return 0;
	}
	for (p = cPath; *p != '\0'; p = (*q == '\0') ? q : q + 1) {
		for (q = p; (*q != '\0') && (*q != cSep); q++) {
		}
		nLen = (size_t)(q - p);
		if (nLen == 0 || nLen >= sizeof(cDir)) {
			continue;
		}
		memcpy(cDir, p, nLen);
		cDir[nLen] = '\0';
		n = snprintf(cProbe, sizeof(cProbe), "%s/%s", cDir, cExe);
		if (n <= 0 || (size_t)n >= sizeof(cProbe)) {
			continue;
		}
		if (stat(cProbe, &st) != 0) {
			continue;
		}
		/* Found <home>/bin/ring — the home is one level up. Trailing
		** separators are trimmed first so ".../bin/" answers the same
		** as ".../bin". */
		while (nLen > 0 && (cDir[nLen - 1] == '/' || cDir[nLen - 1] == '\\')) {
			cDir[--nLen] = '\0';
		}
		while (nLen > 0 && cDir[nLen - 1] != '/' && cDir[nLen - 1] != '\\') {
			nLen--;
		}
		while (nLen > 0 && (cDir[nLen - 1] == '/' || cDir[nLen - 1] == '\\')) {
			nLen--;
		}
		if (nLen == 0 || nLen >= nOut) {
			continue;
		}
		memcpy(cOut, cDir, nLen);
		cOut[nLen] = '\0';
		return 1;
	}
	return 0;
}

static const char *rs_ring_home(void) {
	const char *cEnv;
	if (g_home_state != RS_HOME_UNSET) {
		return (g_home_state == RS_HOME_FOUND) ? g_home : NULL;
	}
	g_home_state = RS_HOME_NONE;
	g_home[0] = '\0';

	cEnv = getenv("RINGSERV_RING_HOME");
	if ((cEnv != NULL) && (cEnv[0] != '\0') && (strlen(cEnv) < sizeof(g_home))) {
		/* Taken AS GIVEN, without the bin/ring probe: an operator who
		** names a home has answered the question, and second-guessing
		** them turns an explicit setting into a suggestion. */
		strcpy(g_home, cEnv);
		g_home_state = RS_HOME_FOUND;
		return g_home;
	}
	if (rs_home_from_path(g_home, sizeof(g_home)) && rs_home_looks_right(g_home)) {
		g_home_state = RS_HOME_FOUND;
		return g_home;
	}
	g_home[0] = '\0';
	return NULL;
}

/* Exposed so `ringserv where` can report what was found — a search root
** nobody can see is a search root nobody can debug. */
const char *rs_ring_home_path(void) {
	const char *cHome = rs_ring_home();
	return (cHome == NULL) ? "" : cHome;
}

/* Does this name carry a directory of its own? A bare name is the only
** form the installation is searched for — a path the author wrote
** relative to their own file means their file, not Ring's library. */
extern const char *rs_path_anchor(void);

/*
** The bare NAME this path is asking for, or NULL if it is not a library
** request at all.
**
** Two forms count, and the second one cost an afternoon to find:
**
**   1. a bare name — `load "stdlib.ring"`, exactly as written;
**   2. a path the VM ITSELF joined to the current anchor. Ring's loader
**      checks existence with the bare name and then RE-OPENS with its own
**      anchor-joined path, so a fallback that knew only form 1 answered
**      the existence check, watched the real open miss, and produced
**      `Can't open file` for a file it had just found.
**
** Anything else — a path the AUTHOR wrote with a directory in it — is
** refused, because `load "mylib/util.ring"` means THEIR util.ring and must
** never be satisfied by an installation's file of the same name.
*/
static const char *rs_library_name(const char *cPath) {
	const char *cBase = NULL;
	const char *p;
	const char *cAnchor;
	size_t nAnchor;

	if ((cPath == NULL) || (cPath[0] == '\0')) {
		return NULL;
	}
	for (p = cPath; *p != '\0'; p++) {
		if ((*p == '/') || (*p == '\\')) {
			cBase = p + 1;
		}
	}
	if (cBase == NULL) {
		return cPath;                 /* form 1: bare, as written */
	}
	if (cBase[0] == '\0') {
		return NULL;                  /* a directory, not a file */
	}
	cAnchor = rs_path_anchor();
	if ((cAnchor == NULL) || (cAnchor[0] == '\0')) {
		return NULL;
	}
	nAnchor = strlen(cAnchor);
	/* form 2: exactly <anchor><sep><name>, and nothing deeper. */
	if ((size_t)(cBase - cPath) != nAnchor + 1) {
		return NULL;
	}
	if (strncmp(cPath, cAnchor, nAnchor) != 0) {
		return NULL;
	}
	return cBase;
}

/*
** The fallback: <home>/bin/<name>, then <home>/bin/load/<name>.
**
** The same two places, in the same order, that native Ring searches — its
** exe folder and that folder's load/. Writes the winner into cOut and
** returns it, or NULL when there is nothing to try or nothing matched.
*/
static const char *rs_home_lookup(const char *cPath, char *cOut, size_t nOut) {
	const char *cHome;
	struct stat st;
	int n;
	cPath = rs_library_name(cPath);
	if (cPath == NULL) {
		return NULL;
	}
	cHome = rs_ring_home();
	if (cHome == NULL) {
		return NULL;
	}
	n = snprintf(cOut, nOut, "%s/bin/%s", cHome, cPath);
	if (n > 0 && (size_t)n < nOut && stat(cOut, &st) == 0) {
		return cOut;
	}
	n = snprintf(cOut, nOut, "%s/bin/load/%s", cHome, cPath);
	if (n > 0 && (size_t)n < nOut && stat(cOut, &st) == 0) {
		return cOut;
	}
	return NULL;
}

/*
** The library fallback, for callers that CANNOT go through rs_fopen.
**
** ring_general_fopen() calls _wfopen directly on Windows — the
** -Dfopen=rs_fopen redirection never reaches it — which is why the vendor
** patch for the load anchor already lives inside that function. The same
** is true here: the existence check reached rs_fopen and found the file,
** the real open went straight to _wfopen and did not, and the loader
** reported "Can't open file" for a file it had just located.
**
** Returns a home-resolved path in cOut, or cPath unchanged.
*/
const char *rs_library_resolve(const char *cPath, char *cOut, int nOut) {
	const char *cFound;
	if ((cPath == NULL) || (cOut == NULL) || (nOut <= 0)) {
		return cPath;
	}
	cFound = rs_home_lookup(cPath, cOut, (size_t)nOut);
	return (cFound == NULL) ? cPath : cFound;
}

FILE *rs_fopen(const char *cPath, const char *cMode) {
	size_t nLen;
	const unsigned char *pData;
	FILE *pFile;
	char cResolved[RS_STUB_PATHSIZE];
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
	pFile = fopen(rs_path_resolve(cPath, cResolved, RS_STUB_PATHSIZE), cMode);
	if ((pFile == NULL) && (cMode != NULL) && (cMode[0] == 'r')) {
		/* Only after the ordinary answer has failed: an application's own
		** file must always win over an installation's, or a library
		** upgrade could silently take over a name the author owns. */
		char cHome[RS_STUB_PATHSIZE];
		const char *cFound = rs_home_lookup(cPath, cHome, sizeof(cHome));
		if (cFound == NULL) {
			/* Last resort: a library's own relative dependency, resolved
			** against where that library lives rather than against the
			** application's anchor. Only reached after the anchor missed. */
			cFound = rs_path_library_join(cPath, cHome, RS_STUB_PATHSIZE);
		}
		if (cFound != NULL) {
			pFile = fopen(cFound, cMode);
			if (pFile != NULL) {
				/* Remember where it lives, so its own
				** `/../../libraries/...` dependencies can resolve. NOT by
				** moving the anchor: scanner.c saves the current directory
				** AFTER the open, so a move here lands inside the VM's save
				** window and is restored as though it had always been the
				** anchor — which broke every relative load for the rest of
				** the run. See rs_path_set_library_dir. */
				rs_path_set_library_dir(cFound);
			}
		}
	}
	return pFile;
}

int rs_stat(const char *cPath, struct stat *pBuf) {
	size_t nLen;
	const unsigned char *pData;
	char cResolved[RS_STUB_PATHSIZE];
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
	if (stat(rs_path_resolve(cPath, cResolved, RS_STUB_PATHSIZE), pBuf) == 0) {
		return 0;
	}
	{
		/* Same fallback as rs_fopen, and for the same reason it must be
		** the same: a VM that can stat a file it cannot open, or the
		** reverse, reports "missing" for something that is there. */
		char cHome[RS_STUB_PATHSIZE];
		const char *cFound = rs_home_lookup(cPath, cHome, sizeof(cHome));
		if (cFound != NULL) {
			return stat(cFound, pBuf);
		}
	}
	return -1;
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
** SQLITE_TRANSIENT is `((sqlite3_destructor_type)-1)` — a C macro that
** casts -1 to a FUNCTION POINTER. Zig's translate-c refuses that on
** aarch64 (code pointers there require an aligned address), which broke
** the linux-arm64 and macos-arm64 cross-builds. Binding through this
** shim keeps the macro on the C side, where it is legal, and costs one
** call.
*/
#include "sqlite3.h"

int rs_bind_text(sqlite3_stmt *pStmt, int nIdx, const char *cStr, int nLen) {
	return sqlite3_bind_text(pStmt, nIdx, cStr, nLen, SQLITE_TRANSIENT);
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
