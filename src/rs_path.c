/*
** RingServ — the load anchor: a per-thread VIRTUAL working directory.
**
** WHY THIS FILE EXISTS
**
** Ring's `load` is a compile-time directive, and the interpreter anchors a
** nested one against the directory of the file that CONTAINS it. It does that
** with a real chdir: ring_state_runfile() calls ring_general_switchtofilefolder()
** before scanning a loaded file, and the caller chdir's back afterwards
** (ringvm/src/state.c, ringvm/src/stmt.c, ringvm/src/scanner.c). That is the
** whole of Ring's per-file anchoring, and the VM's own logic for it is right.
**
** RingServ builds the VM with -DRING_LIMITEDSYS=1, which sets
** RING_CURRENTDIRFUNCTIONS to 0 and turns ring_general_chdir() into a no-op
** returning 0, and ring_general_currentdir() into a function that fills in
** nothing. So every one of those anchor moves silently did nothing, and every
** nested relative `load` collapsed to the process's working directory — one
** anchor directory for a whole load graph, which satisfies at most one level
** of it. That is the compatibility gap: native `ring` loads a multi-file
** library from a real path and `ringserv run` did not.
**
** WHY NOT SIMPLY TURN chdir BACK ON
**
** chdir is PROCESS-WIDE, and RingServ runs N worker threads that each evaluate
** the application source at boot. Two workers anchoring into two different
** library directories at the same moment would read each other's anchor, and a
** load graph resolved half in one directory and half in another fails in a way
** no test reproduces twice. -DRING_LIMITEDSYS also buys a real property — the
** server never moves the directory it was started from — and this file keeps
** it: the REAL working directory is never changed.
**
** WHAT THIS IS INSTEAD
**
** A virtual working directory in _Thread_local storage: chdir moves this
** thread's idea of "here", currentdir reads it back, and every file the VM
** opens by a relative path is resolved against it first. Each worker anchors
** independently, nothing shared is written, and the process's own directory is
** untouched. The VM's anchoring logic is then correct as authored, because the
** two primitives it was written against finally do something.
**
** SEEDED FROM THE PROCESS DIRECTORY, deliberately. Native `ring app.ring`
** resolves a `load` written IN app.ring against the directory the interpreter
** was started from, not against app.ring's own folder — only files loaded
** BELOW the top level are anchored to their container. RingServ matches that
** exactly rather than improving on it, so `ringserv run` and `ring` resolve the
** same program the same way. tests/loader-gates.js holds them to it by running
** both and diffing.
*/
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <stdlib.h>
#ifdef _WIN32
	#include <direct.h>
	#define RS_PATH_GETCWD _getcwd
	#define RS_PATH_SEP '\\'
#else
	#include <unistd.h>
	#define RS_PATH_GETCWD getcwd
	#define RS_PATH_SEP '/'
#endif

/*
** RING_PATHSIZE, kept as a literal so this file does not pull in ring.h — it
** is compiled WITHOUT the -Dfopen=rs_fopen redirection and must stay that way,
** or the real libc calls below would recurse into the stub layer.
*/
#define RS_PATH_SIZE 8192
/*
** Components one path may hold before normalisation gives up and hands the
** caller's string back untouched. A path is never this deep in practice; the
** bound exists so a hostile path cannot walk off the stack.
*/
#define RS_PATH_DEPTH 256

const char *rs_path_resolve(const char *cPath, char *cOut, int nOut);
int rs_path_chdir(const char *cDir);

/* This thread's virtual working directory, seeded on first use. */
static _Thread_local char g_here[RS_PATH_SIZE];
static _Thread_local int g_here_ready = 0;

/* '/' or '\\', written by code point: escaping a backslash through
** three layers of tooling is how this file was corrupted twice. */
static int rs_path_issep(char ch) {
	return (ch == '/') || (ch == (char)92);
}

static int rs_path_isabs(const char *cPath) {
	if (cPath == NULL || cPath[0] == '\0') {
		return 0;
	}
	if ((cPath[0] == '/') || (cPath[0] == '\\')) {
		return 1;
	}
	/* Windows drive: X: — with or without a separator after it. */
	if (((cPath[0] >= 'A' && cPath[0] <= 'Z') || (cPath[0] >= 'a' && cPath[0] <= 'z')) && (cPath[1] == ':')) {
		return 1;
	}
	return 0;
}

/*
** Normalise cIn into cOut: separators made native, empty and "." components
** dropped, ".." resolved against the components already emitted. Returns 0 on
** success and -1 if the result would not fit or the path is deeper than
** RS_PATH_DEPTH — in which case the caller keeps its original string, so a
** path this file cannot express is never silently rewritten into a wrong one.
**
** ".." is resolved TEXTUALLY, not through the filesystem, so a path crossing a
** symbolic link normalises to somewhere a real chdir would not have gone. That
** is the one place this differs from the interpreter, and docs/LOADING.md says so.
*/
static int rs_path_norm(const char *cIn, char *cOut, int nOut) {
	int nStack[RS_PATH_DEPTH];
	int nTop = 0, nLen = 0, nBase = 0, nMark, nSeg;
	const char *p, *q;
	if (cIn == NULL || cOut == NULL || nOut < 4) {
		return -1;
	}
	p = cIn;
	if (((p[0] >= 'A' && p[0] <= 'Z') || (p[0] >= 'a' && p[0] <= 'z')) && (p[1] == ':')) {
		/* Drive prefix — kept verbatim, never a component. */
		cOut[nLen++] = p[0];
		cOut[nLen++] = ':';
		p += 2;
		if ((*p == '/') || (*p == '\\')) {
			cOut[nLen++] = RS_PATH_SEP;
			p++;
		}
	} else if (((p[0] == '/') || (p[0] == '\\')) && ((p[1] == '/') || (p[1] == '\\'))) {
		/* UNC \\server\share — the two leading separators are the root. */
		cOut[nLen++] = RS_PATH_SEP;
		cOut[nLen++] = RS_PATH_SEP;
		p += 2;
	} else if ((p[0] == '/') || (p[0] == '\\')) {
		cOut[nLen++] = RS_PATH_SEP;
		p++;
	}
	nBase = nLen;
	while (*p != '\0') {
		while ((*p == '/') || (*p == '\\')) {
			p++;
		}
		if (*p == '\0') {
			break;
		}
		q = p;
		while ((*q != '\0') && (*q != '/') && (*q != '\\')) {
			q++;
		}
		nSeg = (int)(q - p);
		if ((nSeg == 1) && (p[0] == '.')) {
			/* "." — no move. */
		} else if ((nSeg == 2) && (p[0] == '.') && (p[1] == '.')) {
			if (nTop > 0) {
				/* Popping to the mark drops the separator with the component. */
				nLen = nStack[--nTop];
			} else if (nBase == 0) {
				/* Relative path with nothing to pop: ".." stays literal. */
				if (nLen + 4 >= nOut) {
					return -1;
				}
				if (nLen > nBase) {
					cOut[nLen++] = RS_PATH_SEP;
				}
				cOut[nLen++] = '.';
				cOut[nLen++] = '.';
			}
			/* Absolute path already at its root: ".." is a no-op, as the OS has it. */
		} else {
			if (nTop >= RS_PATH_DEPTH) {
				return -1;
			}
			nMark = nLen;
			if (nLen + nSeg + 2 >= nOut) {
				return -1;
			}
			if (nLen > nBase) {
				cOut[nLen++] = RS_PATH_SEP;
			}
			memcpy(cOut + nLen, p, (size_t)nSeg);
			nLen += nSeg;
			nStack[nTop++] = nMark;
		}
		p = q;
	}
	if (nLen == 0) {
		cOut[nLen++] = '.';
	}
	cOut[nLen] = '\0';
	return 0;
}

/*
** This thread's virtual directory, seeded on first use. Never NULL; "" means
** the real working directory could not be read, and then every resolve below
** hands the caller's path back untouched — which is exactly the behaviour
** RingServ had before this file existed, not a guess at a better one.
*/
static const char *rs_path_here(void) {
	char cReal[RS_PATH_SIZE];
	if (g_here_ready) {
		return g_here;
	}
	g_here_ready = 1;
	g_here[0] = '\0';
	if (RS_PATH_GETCWD(cReal, RS_PATH_SIZE) == NULL) {
		return g_here;
	}
	if (rs_path_norm(cReal, g_here, RS_PATH_SIZE) != 0) {
		g_here[0] = '\0';
	}
	return g_here;
}

/* ring_general_currentdir's body — see the marked patch in ringvm/src/general.c. */
/* The anchor, for the library fallback in native_stubs.c: it must be able
** to tell a path the VM joined itself from one an author wrote. */
/*
** Anchor to the DIRECTORY of a file the library fallback just resolved.
**
** Needed because Ring's loader switches to a loaded file's folder using the
** name AS WRITTEN — `switchtofilefolder("stdlib.ring")` has no directory in
** it and therefore moves nothing. That is correct for a file found relative
** to the anchor, and wrong for one found in a Ring installation: its own
** dependencies are written `/../../libraries/...`, relative to where IT
** lives, and without this they resolve against the application instead.
**
** The VM saves and restores the current directory around every load, and
** currentdir() reads this same virtual directory, so the restore still
** works and the move is scoped to the file that caused it.
*/
void rs_path_anchor_to_file(const char *cFile) {
	char cDir[RS_PATH_SIZE];
	size_t nLen;
	if ((cFile == NULL) || (cFile[0] == '\0')) {
		return;
	}
	nLen = strlen(cFile);
	if (nLen >= RS_PATH_SIZE) {
		return;
	}
	while (nLen > 0 && cFile[nLen - 1] != '/' && cFile[nLen - 1] != '\\') {
		nLen--;
	}
	while (nLen > 1 && (cFile[nLen - 1] == '/' || cFile[nLen - 1] == '\\')) {
		nLen--;
	}
	if (nLen == 0) {
		return;
	}
	memcpy(cDir, cFile, nLen);
	cDir[nLen] = '\0';
	rs_path_chdir(cDir);
}

int rs_path_exists(const char *cPath) {
	struct stat st;
	if ((cPath == NULL) || (cPath[0] == 0)) {
		return 0;
	}
	return stat(cPath, &st) == 0;
}

const char *rs_path_anchor(void) {
	return rs_path_here();
}

int rs_path_getcwd(char *cOut, int nSize) {
	const char *cHere;
	if ((cOut == NULL) || (nSize <= 0)) {
		return -1;
	}
	cHere = rs_path_here();
	if ((int)strlen(cHere) >= nSize) {
		cOut[0] = '\0';
		return -1;
	}
	strcpy(cOut, cHere);
	return 0;
}

/* ring_general_chdir's body. Moves this thread only, and never the process. */
int rs_path_chdir(const char *cDir) {
	char cNext[RS_PATH_SIZE];
	if ((cDir == NULL) || (cDir[0] == '\0')) {
		return -1;
	}
	if (rs_path_resolve(cDir, cNext, RS_PATH_SIZE) != cNext) {
		return -1;
	}
	(void)rs_path_here();
	memcpy(g_here, cNext, strlen(cNext) + 1);
	return 0;
}

/*
** Resolve cPath against this thread's virtual directory. Returns cOut when it
** rewrote the path and cPath itself when it did not — an absolute path that
** will not normalise, a join too long to hold, or a thread whose directory is
** unknown all take the second road, so the worst case is precisely the
** behaviour RingServ had before this file existed.
*/
const char *rs_path_resolve(const char *cPath, char *cOut, int nOut) {
	char cJoin[RS_PATH_SIZE];
	const char *cHere;
	size_t nHere, nPath;
	if ((cPath == NULL) || (cPath[0] == '\0') || (cOut == NULL) || (nOut <= 0)) {
		return cPath;
	}
	/*
	** Ring's own leading-separator form: `load "/../../libraries/x.ring"`,
	** which every file under a Ring installation's bin/load/ uses to reach
	** its dependencies. The leading separator is a MARKER, not a root — the
	** path is relative to the file that wrote it, and `/../..` is never a
	** meaningful absolute path anyway, since the root has no parent.
	**
	** So it is stripped and resolved against the anchor, which for
	** <ring>/bin/load/stdlib.ring gives <ring>/libraries/... exactly as the
	** interpreter produces. The test is deliberately narrow — separator
	** followed by ".." — so a genuine POSIX absolute path can never take
	** this branch.
	*/
	if (rs_path_issep(cPath[0]) &&
	    (cPath[1] == '.') && (cPath[2] == '.') &&
	    (rs_path_issep(cPath[3]) || (cPath[3] == 0))) {
		cPath++;
	} else if (rs_path_isabs(cPath)) {
		return (rs_path_norm(cPath, cOut, nOut) == 0) ? cOut : cPath;
	}
	cHere = rs_path_here();
	if (cHere[0] == '\0') {
		return cPath;
	}
	nHere = strlen(cHere);
	nPath = strlen(cPath);
	if ((nHere + nPath + 2) >= RS_PATH_SIZE) {
		return cPath;
	}
	memcpy(cJoin, cHere, nHere);
	cJoin[nHere] = RS_PATH_SEP;
	memcpy(cJoin + nHere + 1, cPath, nPath + 1);
	return (rs_path_norm(cJoin, cOut, nOut) == 0) ? cOut : cPath;
}
