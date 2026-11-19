# mruby build configuration for mrb.cr.
#
# Pinned upstream commit for mruby 4.0.0:
#   831da26b9021de0369d17b71b5667e2941a1a32d
#
# Only the interpreter core and the compiler are required by the binding.
# Host applications that need more (IO, sockets, time) should build their own
# gembox; this configuration keeps the linked surface small and auditable.
MRuby::Build.new do |conf|
  conf.toolchain

  conf.gem core: "mruby-compiler"
  conf.gem core: "mruby-error"
  # Sebas plugin subprocess sandbox (M3-WP4): print gives scripts a
  # stdout-only channel (no files, no sockets); bin-mruby builds the
  # interpreter executable the host spawns per plugin action.
  conf.gem core: "mruby-sebas-stdio"
  conf.gem core: "mruby-exit"
  conf.gem core: "mruby-bin-mruby"

  if ENV["MRUBY_ASAN"] == "1"
    conf.cc.flags << "-fsanitize=address" << "-fno-omit-frame-pointer" << "-g"
    conf.linker.flags << "-fsanitize=address"
  end

  # Static libraries should be position independent so hosts can link them
  # into shared objects on ELF platforms. MSVC does not understand -fPIC.
  conf.cc.flags << "-fPIC" unless conf.cc.command =~ /\bcl(\.exe)?\b/i
end
