#include <mruby.h>
#include <stdio.h>

/* Sebas plugin sandbox stdio channel: stdout writes ONLY.
   No files, no sockets, no env — keeps the gembox cut auditable. */
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

void
mrb_mruby_sebas_stdio_gem_init(mrb_state *mrb)
{
  mrb_define_method(mrb, mrb->kernel_module, "sebas_print", sebas_print, MRB_ARGS_REQ(1));
}

void
mrb_mruby_sebas_stdio_gem_final(mrb_state *mrb)
{
  (void)mrb; /* stdout-only channel holds no mrb state */
}
