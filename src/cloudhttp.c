/*
 * cloudhttp: HTTP GET for librime-lua scripts running inside Weasel.
 *
 * One background thread owns a WinHTTP session, so the TLS connection to the
 * cloud server stays warm between keystrokes (~70-100 ms instead of ~280 ms).
 * A caller waits at most `timeout_ms`. A late reply is not aborted, since that
 * would drop the warm connection: it lands in the cache instead, and callers
 * stop waiting until the network answers again (see `online`).
 *
 *   local http = require("cloudhttp")
 *   local body, err = http.get(url, timeout_ms)
 *     -- err: "timeout" | "offline" | "failed" | "queued" (timeout_ms <= 0)
 *   http.stats()  -- { online, requests, hits, timeouts, last_ms, last_error }
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "lauxlib.h"
#include "lua.h"

#ifndef WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
#define WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY 4
#endif
#ifndef WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL
#define WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL 133
#endif
#ifndef WINHTTP_PROTOCOL_FLAG_HTTP2
#define WINHTTP_PROTOCOL_FLAG_HTTP2 0x1
#endif

#define CACHE_SIZE 256
#define MAX_URL 2048
#define MAX_HOST 256
/* A reply this late is useless to an IME; give up so the worker can move on. */
#define RESOLVE_TIMEOUT_MS 2000
#define CONNECT_TIMEOUT_MS 2000
#define TRANSFER_TIMEOUT_MS 3000

typedef struct {
  char *url;
  char *body;
  size_t len;
  ULONGLONG used;
} Entry;

static struct {
  INIT_ONCE once;
  CRITICAL_SECTION lock;
  CONDITION_VARIABLE work; /* `pending` was set */
  CONDITION_VARIABLE done; /* a request finished */

  /* Only one request waits: a newer URL replaces the pending one. */
  char *pending, *inflight;
  ULONGLONG seq, pending_seq, inflight_seq, done_seq;

  /* False after a failure or a late reply, until a request succeeds. */
  BOOL online;
  Entry cache[CACHE_SIZE];
  ULONGLONG tick;

  ULONGLONG requests, hits, timeouts;
  DWORD last_ms, last_error;

  /* Worker thread only. */
  HINTERNET session, connect;
  wchar_t connect_host[MAX_HOST];
  INTERNET_PORT connect_port;
} g;

static Entry *cache_find(const char *url) {
  for (int i = 0; i < CACHE_SIZE; i++) {
    if (g.cache[i].url && strcmp(g.cache[i].url, url) == 0) {
      g.cache[i].used = ++g.tick;
      return &g.cache[i];
    }
  }
  return NULL;
}

/* Takes ownership of `body`. */
static void cache_put(const char *url, char *body, size_t len) {
  Entry *e = cache_find(url);
  for (int i = 0; !e && i < CACHE_SIZE; i++) {
    if (!g.cache[i].url) e = &g.cache[i];
  }
  if (!e) {
    e = &g.cache[0];
    for (int i = 1; i < CACHE_SIZE; i++) {
      if (g.cache[i].used < e->used) e = &g.cache[i];
    }
  }
  char *key = e->url && strcmp(e->url, url) == 0 ? e->url : _strdup(url);
  if (!key) {
    free(body);
    return;
  }
  if (key != e->url) free(e->url);
  free(e->body);
  e->url = key;
  e->body = body;
  e->len = len;
  e->used = ++g.tick;
}

/* Worker thread only. Returns a malloc'd, NUL-terminated body, or NULL with
 * *error set to an HTTP status or a WinHTTP error code. */
static char *fetch(const char *url, size_t *len, DWORD *error) {
  wchar_t wurl[MAX_URL];
  URL_COMPONENTS uc = {.dwStructSize = sizeof uc};
  uc.dwHostNameLength = uc.dwUrlPathLength = uc.dwExtraInfoLength = (DWORD)-1;
  if (!MultiByteToWideChar(CP_UTF8, 0, url, -1, wurl, MAX_URL) || !WinHttpCrackUrl(wurl, 0, 0, &uc)) {
    *error = GetLastError();
    return NULL;
  }
  if (uc.dwHostNameLength >= MAX_HOST) {
    *error = ERROR_INVALID_PARAMETER;
    return NULL;
  }

  wchar_t host[MAX_HOST];
  wmemcpy(host, uc.lpszHostName, uc.dwHostNameLength);
  host[uc.dwHostNameLength] = 0;
  if (!g.connect || g.connect_port != uc.nPort || wcscmp(g.connect_host, host) != 0) {
    if (g.connect) WinHttpCloseHandle(g.connect);
    g.connect = WinHttpConnect(g.session, host, uc.nPort, 0);
    if (!g.connect) {
      *error = GetLastError();
      return NULL;
    }
    wcscpy(g.connect_host, host);
    g.connect_port = uc.nPort;
  }

  /* The query string follows the path in `wurl`, so the path pointer covers both. */
  DWORD flags = uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0;
  HINTERNET req = WinHttpOpenRequest(g.connect, L"GET", uc.lpszUrlPath, NULL, WINHTTP_NO_REFERER,
                                     WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
  DWORD status = 0, size = sizeof status;
  char *body = NULL;
  *len = 0;
  *error = 0;
  if (!req || !WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
      !WinHttpReceiveResponse(req, NULL) ||
      !WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                           WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX)) {
    *error = GetLastError();
  } else if (status != 200) {
    *error = status;
  } else {
    for (;;) {
      DWORD avail = 0, got = 0;
      if (!WinHttpQueryDataAvailable(req, &avail)) {
        *error = GetLastError();
        break;
      }
      if (avail == 0) break;
      char *grown = realloc(body, *len + avail + 1);
      if (!grown) {
        *error = ERROR_OUTOFMEMORY;
        break;
      }
      body = grown;
      if (!WinHttpReadData(req, body + *len, avail, &got)) {
        *error = GetLastError();
        break;
      }
      *len += got;
    }
  }
  if (req) WinHttpCloseHandle(req);

  if (!*error && !body) body = malloc(1);
  if (*error || !body) {
    if (!*error) *error = ERROR_OUTOFMEMORY;
    free(body);
    return NULL;
  }
  body[*len] = 0;
  return body;
}

static DWORD WINAPI worker(LPVOID unused) {
  (void)unused;
  LARGE_INTEGER freq;
  QueryPerformanceFrequency(&freq);
  for (;;) {
    EnterCriticalSection(&g.lock);
    while (!g.pending) SleepConditionVariableCS(&g.work, &g.lock, INFINITE);
    char *url = g.pending;
    g.inflight = url;
    g.inflight_seq = g.pending_seq;
    g.pending = NULL;
    LeaveCriticalSection(&g.lock);

    LARGE_INTEGER start, end;
    QueryPerformanceCounter(&start);
    size_t len = 0;
    DWORD error = 0;
    char *body = fetch(url, &len, &error);
    QueryPerformanceCounter(&end);

    EnterCriticalSection(&g.lock);
    g.requests++;
    g.last_ms = (DWORD)((end.QuadPart - start.QuadPart) * 1000 / freq.QuadPart);
    g.last_error = error;
    g.online = body != NULL;
    if (body) cache_put(url, body, len);
    g.done_seq = g.inflight_seq;
    g.inflight = NULL;
    free(url);
    WakeAllConditionVariable(&g.done);
    LeaveCriticalSection(&g.lock);
  }
  return 0;
}

static BOOL CALLBACK init(PINIT_ONCE once, PVOID param, PVOID *context) {
  (void)once;
  (void)param;
  (void)context;
  InitializeCriticalSection(&g.lock);
  InitializeConditionVariable(&g.work);
  InitializeConditionVariable(&g.done);
  g.online = TRUE;

  g.session = WinHttpOpen(L"cloudhttp/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                          WINHTTP_NO_PROXY_BYPASS, 0);
  if (!g.session) return FALSE;
  WinHttpSetTimeouts(g.session, RESOLVE_TIMEOUT_MS, CONNECT_TIMEOUT_MS, TRANSFER_TIMEOUT_MS, TRANSFER_TIMEOUT_MS);
  DWORD http2 = WINHTTP_PROTOCOL_FLAG_HTTP2;
  WinHttpSetOption(g.session, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL, &http2, sizeof http2);

  /* The worker outlives any Lua state that loads us, so never unload. */
  HMODULE self;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                          (LPCWSTR)(void *)&init, &self)) {
    return FALSE;
  }
  HANDLE thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
  if (!thread) return FALSE;
  CloseHandle(thread);
  return TRUE;
}

static int fail(lua_State *L, const char *reason) {
  lua_pushnil(L);
  lua_pushstring(L, reason);
  return 2;
}

/* Lua strings must not be created under the lock (allocation errors unwind),
 * so cache hits are copied out first. */
static char *copy_entry(const Entry *e, size_t *len) {
  char *copy = malloc(e->len + 1);
  if (copy) memcpy(copy, e->body, e->len + 1);
  *len = e->len;
  return copy;
}

static int l_get(lua_State *L) {
  const char *url = luaL_checkstring(L, 1);
  lua_Integer timeout = luaL_optinteger(L, 2, 200);
  luaL_argcheck(L, strlen(url) < MAX_URL, 1, "URL too long");
  if (!InitOnceExecuteOnce(&g.once, init, NULL, NULL)) return fail(L, "unavailable");

  char *body = NULL;
  size_t len = 0;
  const char *reason = NULL;
  EnterCriticalSection(&g.lock);
  Entry *e = cache_find(url);
  if (e) {
    g.hits++;
    body = copy_entry(e, &len);
    if (!body) reason = "failed";
  } else {
    ULONGLONG seq = 0;
    if (g.inflight && strcmp(g.inflight, url) == 0) {
      seq = g.inflight_seq;
    } else if (g.pending && strcmp(g.pending, url) == 0) {
      seq = g.pending_seq;
    } else {
      char *copy = _strdup(url);
      if (copy) {
        free(g.pending);
        g.pending = copy;
        seq = g.pending_seq = ++g.seq;
        WakeConditionVariable(&g.work);
      }
    }

    if (timeout <= 0) {
      reason = "queued";
    } else if (!g.online) {
      reason = "offline";
    } else {
      ULONGLONG deadline = GetTickCount64() + (ULONGLONG)timeout;
      while (!reason && !body) {
        if ((e = cache_find(url))) {
          body = copy_entry(e, &len);
          if (!body) reason = "failed";
        } else if (g.done_seq >= seq) {
          reason = "failed";
        } else {
          ULONGLONG now = GetTickCount64();
          if (now >= deadline) {
            g.timeouts++;
            g.online = FALSE;
            reason = "timeout";
          } else {
            SleepConditionVariableCS(&g.done, &g.lock, (DWORD)(deadline - now));
          }
        }
      }
    }
  }
  LeaveCriticalSection(&g.lock);

  if (!body) return fail(L, reason);
  lua_pushlstring(L, body, len);
  free(body);
  return 1;
}

static int l_stats(lua_State *L) {
  if (!InitOnceExecuteOnce(&g.once, init, NULL, NULL)) return fail(L, "unavailable");
  EnterCriticalSection(&g.lock);
  BOOL online = g.online;
  ULONGLONG requests = g.requests, hits = g.hits, timeouts = g.timeouts;
  DWORD last_ms = g.last_ms, last_error = g.last_error;
  LeaveCriticalSection(&g.lock);

  lua_createtable(L, 0, 6);
  lua_pushboolean(L, online);
  lua_setfield(L, -2, "online");
  lua_pushinteger(L, (lua_Integer)requests);
  lua_setfield(L, -2, "requests");
  lua_pushinteger(L, (lua_Integer)hits);
  lua_setfield(L, -2, "hits");
  lua_pushinteger(L, (lua_Integer)timeouts);
  lua_setfield(L, -2, "timeouts");
  lua_pushinteger(L, last_ms);
  lua_setfield(L, -2, "last_ms");
  lua_pushinteger(L, last_error);
  lua_setfield(L, -2, "last_error");
  return 1;
}

__declspec(dllexport) int luaopen_cloudhttp(lua_State *L) {
  static const luaL_Reg functions[] = {
      {"get", l_get},
      {"stats", l_stats},
      {NULL, NULL},
  };
  luaL_newlib(L, functions);
  return 1;
}
