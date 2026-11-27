/* Sebas plugin sandbox JSON channel (M3-WP4, #16): JSON.parse / JSON.generate.
   Self-written RFC 8259 subset keeps the sandbox gem audit surface consistent
   with mruby-sebas-stdio (no third-party C code vendored into the gembox).
   Plugin protocol frames (§12.2) are the only inputs/outputs; frames carry
   JSON-like values only (null/bool/number/string/array/object). */

#include <mruby.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

#define SEBAS_JSON_MAX_DEPTH 64

typedef struct {
  mrb_state *mrb;
  const char *p;
  const char *end;
  int depth;
} jparse;

static mrb_value jparse_value(jparse *j);

static void
jraise(mrb_state *mrb, const char *msg)
{
  mrb_raise(mrb, mrb_class_get(mrb, "StandardError"), msg);
}

static void
jskip_ws(jparse *j)
{
  while (j->p < j->end) {
    char c = *j->p;
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
      j->p++;
    else
      break;
  }
}

static int
jhex(jparse *j)
{
  if (j->p + 4 > j->end)
    jraise(j->mrb, "invalid \\u escape");
  int v = 0;
  for (int i = 0; i < 4; i++) {
    char c = j->p[i];
    v <<= 4;
    if (c >= '0' && c <= '9')
      v |= c - '0';
    else if (c >= 'a' && c <= 'f')
      v |= c - 'a' + 10;
    else if (c >= 'A' && c <= 'F')
      v |= c - 'A' + 10;
    else
      jraise(j->mrb, "invalid \\u escape");
  }
  j->p += 4;
  return v;
}

static void
jutf8_append(mrb_state *mrb, mrb_value s, unsigned int cp)
{
  char buf[4];
  int n;
  if (cp < 0x80) {
    buf[0] = (char)cp;
    n = 1;
  }
  else if (cp < 0x800) {
    buf[0] = (char)(0xC0 | (cp >> 6));
    buf[1] = (char)(0x80 | (cp & 0x3F));
    n = 2;
  }
  else if (cp < 0x10000) {
    buf[0] = (char)(0xE0 | (cp >> 12));
    buf[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    buf[2] = (char)(0x80 | (cp & 0x3F));
    n = 3;
  }
  else {
    buf[0] = (char)(0xF0 | (cp >> 18));
    buf[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = (char)(0x80 | (cp & 0x3F));
    n = 4;
  }
  mrb_str_cat(mrb, s, buf, (mrb_int)n);
}

static mrb_value
jparse_string(jparse *j)
{
  mrb_state *mrb = j->mrb;
  j->p++; /* opening quote */
  mrb_value s = mrb_str_new_capa(mrb, 16);
  while (j->p < j->end) {
    char c = *j->p++;
    if ((unsigned char)c < 0x20)
      jraise(mrb, "unescaped control character in string");
    if (c != '"') {
      if (c != '\\') {
        mrb_str_cat(mrb, s, &c, 1);
        continue;
      }
      if (j->p >= j->end)
        jraise(mrb, "unterminated escape");
      char e = *j->p++;
      switch (e) {
      case '"':
        mrb_str_cat_lit(mrb, s, "\"");
        break;
      case '\\':
        mrb_str_cat_lit(mrb, s, "\\");
        break;
      case '/':
        mrb_str_cat_lit(mrb, s, "/");
        break;
      case 'b':
        mrb_str_cat_lit(mrb, s, "\b");
        break;
      case 'f':
        mrb_str_cat_lit(mrb, s, "\f");
        break;
      case 'n':
        mrb_str_cat_lit(mrb, s, "\n");
        break;
      case 'r':
        mrb_str_cat_lit(mrb, s, "\r");
        break;
      case 't':
        mrb_str_cat_lit(mrb, s, "\t");
        break;
      case 'u': {
        unsigned int cp = (unsigned int)jhex(j);
        if (cp >= 0xD800 && cp <= 0xDBFF) {
          /* high surrogate: require a following \uDC00-\uDFFF pair */
          if (j->p + 6 > j->end || j->p[0] != '\\' || j->p[1] != 'u')
            jraise(mrb, "unpaired surrogate in \\u escape");
          j->p += 2;
          unsigned int lo = (unsigned int)jhex(j);
          if (lo < 0xDC00 || lo > 0xDFFF)
            jraise(mrb, "invalid surrogate pair in \\u escape");
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
        }
        else if (cp >= 0xDC00 && cp <= 0xDFFF) {
          jraise(mrb, "unpaired surrogate in \\u escape");
        }
        jutf8_append(mrb, s, cp);
        break;
      }
      default:
        jraise(mrb, "invalid escape character");
      }
      continue;
    }
    return s;
  }
  jraise(mrb, "unterminated string");
  return mrb_nil_value(); /* unreachable */
}

static mrb_value
jparse_number(jparse *j)
{
  mrb_state *mrb = j->mrb;
  const char *start = j->p;
  int is_float = 0;
  if (j->p < j->end && (*j->p == '-' || *j->p == '+'))
    j->p++;
  while (j->p < j->end) {
    char c = *j->p;
    if (c >= '0' && c <= '9') {
      j->p++;
    }
    else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
      is_float = 1;
      j->p++;
    }
    else {
      break;
    }
  }
  if (j->p == start)
    jraise(mrb, "invalid number");
  char buf[64];
  size_t n = (size_t)(j->p - start);
  if (n >= sizeof(buf))
    jraise(mrb, "number too long");
  memcpy(buf, start, n);
  buf[n] = '\0';
  if (!is_float) {
    errno = 0;
    char *endp = NULL;
    long long v = strtoll(buf, &endp, 10);
    if (errno == 0 && endp && *endp == '\0')
      return mrb_int_value(mrb, (mrb_int)v);
  }
  return mrb_float_value(mrb, strtod(buf, NULL));
}

static mrb_value
jparse_value(jparse *j)
{
  mrb_state *mrb = j->mrb;
  jskip_ws(j);
  if (j->p >= j->end)
    jraise(mrb, "unexpected end of input");
  if (++j->depth > SEBAS_JSON_MAX_DEPTH) {
    j->depth--;
    jraise(mrb, "nesting too deep");
  }
  mrb_value out = mrb_nil_value();
  char c = *j->p;
  if (c == '"') {
    out = jparse_string(j);
  }
  else if (c == '{') {
    j->p++;
    out = mrb_hash_new_capa(mrb, 4);
    jskip_ws(j);
    if (j->p < j->end && *j->p == '}') {
      j->p++;
    }
    else {
      for (;;) {
        jskip_ws(j);
        if (j->p >= j->end || *j->p != '"')
          jraise(mrb, "object key must be a string");
        mrb_value key = jparse_string(j);
        jskip_ws(j);
        if (j->p >= j->end || *j->p != ':')
          jraise(mrb, "expected ':' in object");
        j->p++;
        mrb_value val = jparse_value(j);
        mrb_hash_set(mrb, out, key, val);
        jskip_ws(j);
        if (j->p < j->end && *j->p == ',') {
          j->p++;
          continue;
        }
        if (j->p < j->end && *j->p == '}') {
          j->p++;
          break;
        }
        jraise(mrb, "expected ',' or '}' in object");
      }
    }
  }
  else if (c == '[') {
    j->p++;
    out = mrb_ary_new_capa(mrb, 4);
    jskip_ws(j);
    if (j->p < j->end && *j->p == ']') {
      j->p++;
    }
    else {
      for (;;) {
        mrb_value val = jparse_value(j);
        mrb_ary_push(mrb, out, val);
        jskip_ws(j);
        if (j->p < j->end && *j->p == ',') {
          j->p++;
          continue;
        }
        if (j->p < j->end && *j->p == ']') {
          j->p++;
          break;
        }
        jraise(mrb, "expected ',' or ']' in array");
      }
    }
  }
  else if (c == 't') {
    if (j->end - j->p < 4 || strncmp(j->p, "true", 4) != 0)
      jraise(mrb, "invalid literal");
    j->p += 4;
    out = mrb_true_value();
  }
  else if (c == 'f') {
    if (j->end - j->p < 5 || strncmp(j->p, "false", 5) != 0)
      jraise(mrb, "invalid literal");
    j->p += 5;
    out = mrb_false_value();
  }
  else if (c == 'n') {
    if (j->end - j->p < 4 || strncmp(j->p, "null", 4) != 0)
      jraise(mrb, "invalid literal");
    j->p += 4;
    out = mrb_nil_value();
  }
  else if (c == '-' || (c >= '0' && c <= '9')) {
    out = jparse_number(j);
  }
  else {
    jraise(mrb, "unexpected character");
  }
  j->depth--;
  return out;
}

static mrb_value
mrb_json_parse(mrb_state *mrb, mrb_value self)
{
  const char *str;
  mrb_int len;
  mrb_get_args(mrb, "s", &str, &len);
  jparse j = {mrb, str, str + len, 0};
  mrb_value out = jparse_value(&j);
  jskip_ws(&j);
  if (j.p != j.end)
    jraise(mrb, "trailing characters after JSON value");
  return out;
}

/* ---- generate ---- */

static void jgen_value(mrb_state *mrb, mrb_value v, mrb_value out, int depth);

static int
jutf16_len(unsigned int cp)
{
  return (cp >= 0x10000) ? 2 : 1;
}

static void
jgen_string(mrb_state *mrb, mrb_value str, mrb_value out)
{
  const char *p = RSTRING_PTR(str);
  mrb_int len = RSTRING_LEN(str);
  char buf[8];
  mrb_str_cat_lit(mrb, out, "\"");
  for (mrb_int i = 0; i < len; i++) {
    unsigned char c = (unsigned char)p[i];
    switch (c) {
    case '"':
      mrb_str_cat_lit(mrb, out, "\\\"");
      break;
    case '\\':
      mrb_str_cat_lit(mrb, out, "\\\\");
      break;
    case '\n':
      mrb_str_cat_lit(mrb, out, "\\n");
      break;
    case '\r':
      mrb_str_cat_lit(mrb, out, "\\r");
      break;
    case '\t':
      mrb_str_cat_lit(mrb, out, "\\t");
      break;
    case '\b':
      mrb_str_cat_lit(mrb, out, "\\b");
      break;
    case '\f':
      mrb_str_cat_lit(mrb, out, "\\f");
      break;
    default:
      if (c < 0x20) {
        snprintf(buf, sizeof(buf), "\\u%04x", c);
        mrb_str_cat(mrb, out, buf, 6);
      }
      else {
        mrb_str_cat(mrb, out, (const char *)&p[i], 1); /* raw UTF-8 byte */
      }
    }
  }
  mrb_str_cat_lit(mrb, out, "\"");
}

static void
jgen_number(mrb_state *mrb, mrb_value v, mrb_value out)
{
  char buf[40];
  if (mrb_integer_p(v)) {
    snprintf(buf, sizeof(buf), "%lld", (long long)mrb_integer(v));
  }
  else {
    mrb_float f = mrb_float(v);
    if (!(f == f) || f - f != 0.0) /* NaN / inf: not representable in JSON */
      mrb_raise(mrb, mrb_class_get(mrb, "StandardError"), "cannot generate non-finite float as JSON");
    snprintf(buf, sizeof(buf), "%.17g", (double)f);
  }
  mrb_str_cat(mrb, out, buf, (mrb_int)strlen(buf));
}

static void
jgen_value(mrb_state *mrb, mrb_value v, mrb_value out, int depth)
{
  if (depth > SEBAS_JSON_MAX_DEPTH)
    mrb_raise(mrb, mrb_class_get(mrb, "StandardError"), "nesting too deep");
  if (mrb_nil_p(v)) {
    mrb_str_cat_lit(mrb, out, "null");
  }
  else if (mrb_true_p(v)) {
    mrb_str_cat_lit(mrb, out, "true");
  }
  else if (mrb_false_p(v)) {
    mrb_str_cat_lit(mrb, out, "false");
  }
  else if (mrb_string_p(v)) {
    jgen_string(mrb, v, out);
  }
  else if (mrb_integer_p(v) || mrb_float_p(v)) {
    jgen_number(mrb, v, out);
  }
  else if (mrb_array_p(v)) {
    mrb_str_cat_lit(mrb, out, "[");
    mrb_int n = RARRAY_LEN(v);
    for (mrb_int i = 0; i < n; i++) {
      if (i > 0)
        mrb_str_cat_lit(mrb, out, ",");
      jgen_value(mrb, mrb_ary_ref(mrb, v, i), out, depth + 1);
    }
    mrb_str_cat_lit(mrb, out, "]");
  }
  else if (mrb_hash_p(v)) {
    mrb_str_cat_lit(mrb, out, "{");
    mrb_value keys = mrb_hash_keys(mrb, v);
    mrb_int n = RARRAY_LEN(keys);
    for (mrb_int i = 0; i < n; i++) {
      mrb_value key = mrb_ary_ref(mrb, keys, i);
      if (!mrb_string_p(key))
        mrb_raise(mrb, mrb_class_get(mrb, "StandardError"), "hash key must be a String");
      if (i > 0)
        mrb_str_cat_lit(mrb, out, ",");
      jgen_string(mrb, key, out);
      mrb_str_cat_lit(mrb, out, ":");
      jgen_value(mrb, mrb_hash_get(mrb, v, key), out, depth + 1);
    }
    mrb_str_cat_lit(mrb, out, "}");
  }
  else {
    mrb_raise(mrb, mrb_class_get(mrb, "StandardError"),
              "only JSON-like values (nil/bool/number/string/array/hash) can be generated");
  }
}

static mrb_value
mrb_json_generate(mrb_state *mrb, mrb_value self)
{
  mrb_value v;
  mrb_get_args(mrb, "o", &v);
  mrb_value out = mrb_str_new_capa(mrb, 64);
  jgen_value(mrb, v, out, 0);
  return out;
}

void
mrb_mruby_sebas_json_gem_init(mrb_state *mrb)
{
  struct RClass *json = mrb_define_module(mrb, "JSON");
  mrb_define_module_function(mrb, json, "parse", mrb_json_parse, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, json, "generate", mrb_json_generate, MRB_ARGS_REQ(1));
}

void
mrb_mruby_sebas_json_gem_final(mrb_state *mrb)
{
  (void)mrb; /* parser holds no mrb state between calls */
}
