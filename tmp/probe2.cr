require "../src/platform/store/store"
require "file_utils"
dir = Path[Dir.tempdir, "pragma-probe2", Random::Secure.hex(4)]
FileUtils.mkdir_p(dir)
store = Sebas::Platform::Store::Store.new(dir / "db.sqlite")
p store.db.query_all("SELECT name FROM pragma_table_info('expectations')", as: String)
