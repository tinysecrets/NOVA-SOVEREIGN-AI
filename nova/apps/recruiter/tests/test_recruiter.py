import tempfile
import unittest
from pathlib import Path

from recruit.config import RecruiterConfig, load_config
from recruit.compliance import Compliance
from recruit.prospects import ProspectStore, EMAIL_RE


def _cfg(tmp: Path) -> RecruiterConfig:
    import os

    os.environ["RECRUITER_DATA_DIR"] = str(tmp)
    os.environ["RECRUITER_DRY_RUN"] = "true"
    os.environ["RECRUITER_APPROVAL_GATE"] = "true"
    return load_config()


class ComplianceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = _cfg(Path(self.tmp.name))
        self.c = Compliance(self.cfg)

    def tearDown(self):
        self.tmp.cleanup()

    def test_banned_pattern_blocked(self):
        v = self.c.qa_verdict("Try Wah-Lah", "You are guaranteed to win a prize!")
        self.assertEqual(v["verdict"], "FAIL")
        self.assertTrue(any("banned" in i for i in v["issues"]))

    def test_clean_copy_passes_missing_wah_lah(self):
        v = self.c.qa_verdict("Come play", "Hey there, this is a friendly invite from Ember (an AI assistant).")
        self.assertEqual(v["verdict"], "ISSUES")
        self.assertIn("missing_wah_lah_reference", v["issues"])

    def test_optout_honored(self):
        self.assertFalse(self.c.is_opted_out("A@B.com"))
        self.c.opt_out("a@b.com")
        self.assertTrue(self.c.is_opted_out("A@B.COM"))

    def test_rate_ceiling(self):
        self.assertEqual(self.c.remaining_hour(), self.cfg.max_per_hour)
        for _ in range(self.cfg.max_per_hour):
            self.c.record_send("x@y.com")
        self.assertEqual(self.c.remaining_hour(), 0)


class ProspectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = _cfg(Path(self.tmp.name))
        self.c = Compliance(self.cfg)
        self.s = ProspectStore(self.cfg, self.c)

    def tearDown(self):
        self.tmp.cleanup()

    def test_ingest_skips_no_consent_and_dupes(self):
        csv = "email,name,consent\none@wah-lah.com,One,true\ntwo@wah-lah.com,Two,false\none@wah-lah.com,One,true\n"
        res = self.s.ingest_csv(csv)
        self.assertEqual(res["added"], 1)
        self.assertEqual(res["skipped"], 1)
        self.assertEqual(res["dupes"], 1)

    def test_email_re(self):
        self.assertTrue(EMAIL_RE.match("a@b.com"))
        self.assertFalse(EMAIL_RE.match("nope"))


if __name__ == "__main__":
    unittest.main()