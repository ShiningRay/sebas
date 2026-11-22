require "../src/platform/store/store"
require "file_utils"
dir = Path[Dir.tempdir, "pragma-probe", Random::Secure.hex(4)]
FileUtils.mkdir_p(dir)
store = Sebas::Platform::Store::Store.new(dir / "db.sqlite")
p store.db.query_one?("SELECT 1 FROM pragma_table_info(expectations) WHERE name = ?", "members_final", as: Int)
p store.db.query_one?("SELECT count(*) FROM pragma_table_info(expectations)", as: Int)
