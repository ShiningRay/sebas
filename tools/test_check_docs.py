#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_docs.py 的回归测试。

重点钉住行号锚正则的两条边界：
  - 冒号分隔时 `L` 可省（`design.md:473` 是行号引用，必须拦）；
  - 空白分隔时 `L` 不可省（`design.md 16 章` 是章节数量，不能拦）。

用法：python tools/test_check_docs.py
"""

import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check_docs  # noqa: E402


def anchors_in(text):
    return [m.group(0) for m in check_docs.LINE_ANCHOR.finditer(text)]


class LineAnchorTest(unittest.TestCase):
    def test_l_prefixed_colon(self):
        self.assertEqual(anchors_in("见 design.md:L749"), ["design.md:L749"])

    def test_l_prefixed_space(self):
        self.assertEqual(anchors_in("见 design.md L846"), ["design.md L846"])

    def test_bare_number_after_colon(self):
        self.assertEqual(anchors_in("见 design.md:473"), ["design.md:473"])

    def test_range_after_colon(self):
        self.assertEqual(anchors_in("design.md:341-342"), ["design.md:341-342"])

    def test_range_after_colon_with_l(self):
        self.assertEqual(anchors_in("design.md:L921-928"), ["design.md:L921-928"])

    def test_fullwidth_colon(self):
        self.assertEqual(anchors_in("design.md：749"), ["design.md：749"])

    def test_chapter_count_is_not_an_anchor(self):
        # 空白分隔且无 L → 章节数量，不是行号
        self.assertEqual(anchors_in("design.md 16 章"), [])

    def test_plain_section_reference_is_not_an_anchor(self):
        self.assertEqual(anchors_in("design.md §14 与 design.md §5.3"), [])

    def test_development_plan_is_covered(self):
        self.assertEqual(anchors_in("development-plan.md:17"), ["development-plan.md:17"])

    def test_unrelated_filename_is_not_covered(self):
        self.assertEqual(anchors_in("naming.md:12"), [])


class ReviewDirTest(unittest.TestCase):
    """review/ 下的行号锚只告警，不阻断。"""

    def _run(self, rel_dir):
        root = tempfile.mkdtemp()
        target_dir = os.path.join(root, rel_dir)
        os.makedirs(target_dir)
        path = os.path.join(target_dir, "x.md")
        with io.open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("见 design.md:L846\n")
        problems = []
        check_docs.check_line_anchors(path, ["见 design.md:L846"], problems, root)
        return problems

    def test_review_dir_warns(self):
        problems = self._run(os.path.join("docs", "design", "review"))
        self.assertEqual([p[0] for p in problems], ["WARN"])

    def test_other_dir_fails(self):
        problems = self._run(os.path.join("docs", "design", "spec"))
        self.assertEqual([p[0] for p in problems], ["FAIL"])


if __name__ == "__main__":
    unittest.main()
