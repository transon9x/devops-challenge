import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import sql_guard  # noqa: E402


def check(sql: str) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "0001_x.sql"
        path.write_text(sql)
        return sql_guard.problems(path)


class SqlGuardTests(unittest.TestCase):
    def test_plain_additive_migration_is_accepted(self):
        self.assertEqual(check("ALTER TABLE t ADD COLUMN c int;\n"), [])

    def test_commented_transaction_word_is_accepted(self):
        self.assertEqual(check("-- COMMIT;\nALTER TABLE t ADD COLUMN c int;\n"), [])

    def test_transaction_word_in_a_string_is_accepted(self):
        self.assertEqual(
            check("INSERT INTO t (note) VALUES ('COMMIT; rollback');\n"), []
        )

    def test_line_comment_marker_inside_a_string_does_not_hide_a_commit(self):
        self.assertEqual(len(check("SELECT '--'; COMMIT;\n")), 1)

    def test_starred_block_comment_does_not_hide_a_commit(self):
        self.assertEqual(len(check("/*\n * note\n */\nCOMMIT;\n")), 1)

    def test_commit_and_chain_is_refused(self):
        self.assertEqual(len(check("SELECT 1;\nCOMMIT AND CHAIN;\n")), 1)

    def test_abort_alias_is_refused(self):
        self.assertEqual(len(check("ABORT;\n")), 1)

    def test_control_after_another_statement_on_one_line_is_refused(self):
        self.assertEqual(len(check("SELECT 1; BEGIN TRANSACTION;\n")), 1)

    def test_meta_command_is_refused(self):
        self.assertEqual(len(check("\\! echo pwned\n")), 1)

    def test_dollar_quoted_body_may_contain_the_words(self):
        self.assertEqual(
            check("DO $mig$ BEGIN RAISE NOTICE 'commit'; END $mig$;\n"), []
        )

    def test_dollar_tag_inside_two_strings_cannot_swallow_a_commit(self):
        # A pass-per-construct normaliser matched between the two '$x$' substrings and
        # deleted the statement in the middle.
        self.assertEqual(
            len(check("SELECT '$x$'; COMMIT; SELECT 1/0; SELECT '$x$';\n")), 1
        )

    def test_escape_string_with_a_backslash_quote_does_not_hide_a_commit(self):
        self.assertEqual(len(check("SELECT E'a\\'b'; COMMIT;\n")), 1)

    def test_nested_block_comment_is_removed_as_a_whole(self):
        self.assertEqual(
            check("/* a /* b */ c */ ALTER TABLE t ADD COLUMN c int;\n"), []
        )

    def test_comment_markers_in_strings_keep_the_statement_visible(self):
        # The destructive scan runs over the same normalised text, so this must survive it.
        normalised = sql_guard.normalise(
            "SELECT '/*'; ALTER TABLE accounts DROP COLUMN balance; SELECT '*/';"
        )
        self.assertIn("DROP COLUMN balance", normalised)

    def test_dollar_after_identifier_characters_is_not_a_dollar_quote(self):
        # PostgreSQL reads `foo$x$` as one identifier, so the COMMIT between the two is real.
        self.assertEqual(
            len(check("SELECT 1 AS foo$x$; COMMIT; SELECT 1 AS foo$x$;\n")), 1
        )

    def test_non_ascii_identifier_also_bounds_a_dollar_quote(self):
        # PostgreSQL allows accented letters in unquoted identifiers, so `é$x$` is one
        # identifier too and the COMMIT between the two occurrences is real.
        self.assertEqual(
            len(check("SELECT 1 AS \u00e9$x$; COMMIT; SELECT 1 AS \u00e9$x$;\n")), 1
        )

    def test_decomposed_non_ascii_identifier_also_bounds_a_dollar_quote(self):
        # `e` followed by U+0301 is the same identifier to PostgreSQL, whose scanner accepts
        # any byte above ASCII in an identifier without classifying it. A guard that used
        # Python's `\w` would stop at the combining mark and read `$x$` as a dollar quote.
        self.assertEqual(
            len(check("SELECT 1 AS e\u0301$x$; COMMIT; SELECT 1 AS e\u0301$x$;\n")), 1
        )

    def test_dollar_after_a_digit_is_refused_rather_than_swallowed(self):
        # PostgreSQL's scanner would take `$x$` here as a dollar quote, hiding the COMMIT
        # inside a string. The guard does not, on purpose: it reports rather than deletes
        # text across a boundary it cannot place, and such a file does not parse anyway.
        self.assertEqual(len(check("SELECT 1$x$; COMMIT; SELECT 1$x$;\n")), 1)

    def test_nul_byte_is_refused(self):
        # bash deletes NUL from a command substitution, so `COM<NUL>MIT` would reach
        # PostgreSQL as a real COMMIT while reading here as an unknown word.
        found = check("CREATE TABLE t(id int); COM\x00MIT; SELECT 1/0;\n")
        self.assertEqual(len(found), 1)
        self.assertIn("NUL byte", found[0])

    def test_anonymous_dollar_quoted_function_body_is_accepted(self):
        self.assertEqual(
            check(
                "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END $$ "
                "LANGUAGE plpgsql;\n"
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
