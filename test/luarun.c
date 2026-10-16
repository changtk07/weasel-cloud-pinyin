/* luarun: run a Lua script on the Lua 5.4 embedded in Weasel's rime.dll.
 * usage: luarun script.lua [args...]   (args are in the global `arg`) */
#include <stdio.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: luarun script.lua [args...]\n");
    return 2;
  }
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  lua_createtable(L, argc, 0);
  for (int i = 1; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i - 1);
  }
  lua_setglobal(L, "arg");
  int failed = luaL_dofile(L, argv[1]);
  if (failed) fprintf(stderr, "%s\n", lua_tostring(L, -1));
  lua_close(L);
  return failed ? 1 : 0;
}
