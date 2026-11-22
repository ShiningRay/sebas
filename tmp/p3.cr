require "../src/platform/store/store"
require "file_utils"
dir = Path[Dir.tempdir, "p3", Random::Secure.hex(4)]
FileUtils.mkdir_p(dir)
store = Sebas::Platform::Store::Store.new(dir / "db.sqlite")
store.create_task("p", "t")
store.fail_task("p", "x")
p store.task("p").result
