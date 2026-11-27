#include <mruby.h>
#include <mruby/string.h>
#include <stdio.h>

/* Sebas plugin sandbox stdio channel: stdout writes + stdin line reads.
   No files, no sockets, no env — keeps the gembox cut auditable.
   The host runner owns both pipes: stdin carries the request line and
   capability_result reply frames; stdout carries protocol frames only. */
static mrb_value
sebas_print(mrb_state *mrb, mrb_value self)
{
  const char *str;
  mrb_int len;
  mrb_get_args(mrb, "s", &str, &len);
  fwrite(str, 1, (size_t)len, stdout);
  fflush(stdout);
  return mrb_nil_value();
}

/* sebas_read — read one line from stdin; nil at EOF. Trailing \n (and a \r
   right before it) stripped. Blocking: the host writes frames when the
   protocol says so and the watchdog kills the process on timeout. */
static mrb_value
sebas_read(mrb_state *mrb, mrb_value self)
{
  mrb_value s = mrb_str_new_capa(mrb, 256);
  int c;
  int got = 0;
  while ((c = getchar()) != EOF) {
    got = 1;
    if (c == '\n')
      break;
    if (c != '\r') {
      char ch = (char)c;
      mrb_str_cat(mrb, s, &ch, 1);
    }
  }
  if (!got && RSTRING_LEN(s) == 0)
    return mrb_nil_value();
  return s;
}

void
mrb_mruby_sebas_stdio_gem_init(mrb_state *mrb)
{
  mrb_define_method(mrb, mrb->kernel_module, "sebas_print", sebas_print, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, mrb->kernel_module, "sebas_read", sebas_read, MRB_ARGS_NONE());
}

void
mrb_mruby_sebas_stdio_gem_final(mrb_state *mrb)
{
  (void)mrb; /* stdio channel holds no mrb state */
}
