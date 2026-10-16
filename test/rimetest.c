/* rimetest: drive librime (Weasel's rime.dll) without a UI, for tests.
 *
 * usage: rimetest <shared_data_dir> <user_data_dir> <log_dir> command...
 *   deploy               rebuild everything (otherwise only what changed)
 *   schema <id>          select a schema
 *   opt <name> <0|1>     set an option, e.g. traditionalization
 *   keys <sequence>      type keys, e.g. womenqugongyuan or {space} or {Control+Shift+dollar}
 *   type <letters>       type one key at a time, building the menu after each like
 *                        a frontend does, and report per-key latency
 *   show                 print input, preedit and the first page of candidates
 *   select <n>           pick candidate n (1-based) on the current page
 *   clear                drop the current composition
 *   sleep <ms>
 * Commits are printed as they happen. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#include "rime_api.h"

static RimeApi *rime;
static LARGE_INTEGER freq;

static long long now_ms(void) {
  LARGE_INTEGER t;
  QueryPerformanceCounter(&t);
  return t.QuadPart * 1000 / freq.QuadPart;
}

/* Process keys and build the menu, as a frontend would after each key. */
static long long press(RimeSessionId session, const char *keys) {
  long long start = now_ms();
  rime->simulate_key_sequence(session, keys);
  RIME_STRUCT(RimeContext, ctx);
  if (rime->get_context(session, &ctx)) rime->free_context(&ctx);
  return now_ms() - start;
}

static void print_commit(RimeSessionId session) {
  RIME_STRUCT(RimeCommit, commit);
  if (rime->get_commit(session, &commit)) {
    printf("commit: %s\n", commit.text);
    rime->free_commit(&commit);
  }
}

static void show(RimeSessionId session) {
  RIME_STRUCT(RimeContext, ctx);
  if (!rime->get_context(session, &ctx)) return;
  const char *input = rime->get_input(session);
  printf("input: %s\npreedit: %s\n", input ? input : "", ctx.composition.preedit ? ctx.composition.preedit : "");
  for (int i = 0; i < ctx.menu.num_candidates; i++) {
    RimeCandidate *c = &ctx.menu.candidates[i];
    printf("%c%d. %s%s%s\n", i == ctx.menu.highlighted_candidate_index ? '*' : ' ', i + 1, c->text,
           c->comment ? " " : "", c->comment ? c->comment : "");
  }
  rime->free_context(&ctx);
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: rimetest <shared_data_dir> <user_data_dir> <log_dir> command...\n");
    return 2;
  }
  setvbuf(stdout, NULL, _IONBF, 0);
  QueryPerformanceFrequency(&freq);
  rime = rime_get_api();

  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.log_dir = argv[3];
  traits.distribution_name = "rimetest";
  traits.distribution_code_name = "rimetest";
  traits.distribution_version = "0.1";
  traits.app_name = "rime.rimetest";
  rime->setup(&traits);
  rime->initialize(&traits);

  int full_check = 0;
  for (int i = 4; i < argc; i++) {
    if (strcmp(argv[i], "deploy") == 0) full_check = 1;
  }
  if (rime->start_maintenance(full_check)) rime->join_maintenance_thread();

  RimeSessionId session = rime->create_session();
  for (int i = 4; i < argc; i++) {
    const char *cmd = argv[i];
    const char *a = i + 1 < argc ? argv[i + 1] : "";
    if (strcmp(cmd, "deploy") == 0) {
      continue;
    } else if (strcmp(cmd, "schema") == 0) {
      printf("schema %s: %s\n", a, rime->select_schema(session, a) ? "ok" : "FAILED");
      i++;
    } else if (strcmp(cmd, "opt") == 0 && i + 2 < argc) {
      rime->set_option(session, a, atoi(argv[i + 2]) != 0);
      i += 2;
    } else if (strcmp(cmd, "keys") == 0) {
      printf("keys %s (%lld ms)\n", a, press(session, a));
      print_commit(session);
      i++;
    } else if (strcmp(cmd, "type") == 0) {
      printf("type %s:", a);
      for (const char *p = a; *p; p++) {
        char key[2] = {*p, 0};
        printf(" %lld", press(session, key));
      }
      printf(" ms\n");
      print_commit(session);
      i++;
    } else if (strcmp(cmd, "show") == 0) {
      show(session);
    } else if (strcmp(cmd, "select") == 0) {
      rime->select_candidate_on_current_page(session, (size_t)(atoi(a) - 1));
      print_commit(session);
      i++;
    } else if (strcmp(cmd, "clear") == 0) {
      rime->clear_composition(session);
    } else if (strcmp(cmd, "sleep") == 0) {
      Sleep((DWORD)atoi(a));
      i++;
    } else {
      fprintf(stderr, "unknown command: %s\n", cmd);
      return 2;
    }
  }
  rime->destroy_session(session);
  rime->finalize();
  return 0;
}
