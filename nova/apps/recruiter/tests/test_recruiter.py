import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from recruit.config import FREE_ROUTER_MODEL, RecruiterConfig, load_config
from recruit.compliance import Compliance
from recruit.prospects import ProspectStore, EMAIL_RE
from recruit.senders import Senders, unsubscribe_token, verify_unsubscribe_token


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


class ReleaseSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_paid_and_google_model_overrides_fall_back_to_free(self):
        cfg = RecruiterConfig(
            root=self.root,
            data_dir=self.root,
            yaml={},
            env={
                "OPENROUTER_API_KEY": "test-key-not-used",
                "OPENROUTER_MODEL": "nousresearch/hermes-4-70b",
                "OPENROUTER_MODEL_HIGH": "google/gemma-4-26b-a4b-it:free",
            },
            openrouter_api_key="test-key-not-used",
            model_routine="nousresearch/hermes-4-70b",
            model_high="google/gemma-4-26b-a4b-it:free",
        )
        self.assertEqual(cfg.model_for(), FREE_ROUTER_MODEL)
        self.assertEqual(cfg.model_for(high=True), FREE_ROUTER_MODEL)
        self.assertEqual(cfg.brain, {"provider": "openrouter", "model": FREE_ROUTER_MODEL})

    def test_ollama_cloud_setting_is_forced_to_local(self):
        cfg = RecruiterConfig(
            root=self.root,
            data_dir=self.root,
            yaml={},
            env={"RECRUITER_BRAIN": "ollama_cloud", "OLLAMA_API_KEY": "test-key-not-used"},
            ollama_api_key="test-key-not-used",
        )
        self.assertEqual(cfg.brain["provider"], "ollama_local")

    def test_missing_unsubscribe_secret_blocks_live_email_before_network(self):
        cfg = RecruiterConfig(
            root=self.root,
            data_dir=self.root,
            yaml={"compliance": {"add_list_unsubscribe": True}},
            env={"UNSUBSCRIBE_BASE_URL": "https://app.wah-lah.com"},
            resend_api_key="test-key-not-used",
            postal_address="Test Address (test only)",
        )
        result = Senders(cfg).send_email(to="test@example.com", subject="Test", body="Test")
        self.assertFalse(result["ok"])
        self.assertIn("UNSUBSCRIBE_SECRET", result["detail"])

    def test_unsubscribe_token_requires_real_secret_and_normalizes_email(self):
        with self.assertRaises(ValueError):
            unsubscribe_token("test@example.com", "recruiter-secret")
        secret = "random-local-test-secret-with-more-than-32-characters"
        token = unsubscribe_token("Test@Example.com", secret)
        self.assertEqual(token, unsubscribe_token("test@example.com", secret))
        self.assertTrue(verify_unsubscribe_token("test@example.com", token, secret))
        self.assertFalse(verify_unsubscribe_token("other@example.com", token, secret))
        self.assertFalse(verify_unsubscribe_token("test@example.com", "0" * 32, secret))

    def test_unsubscribe_url_is_https_and_signs_encoded_address(self):
        secret = "random-local-test-secret-with-more-than-32-characters"
        cfg = RecruiterConfig(
            root=self.root,
            data_dir=self.root,
            yaml={},
            env={"UNSUBSCRIBE_BASE_URL": "https://app.wah-lah.com", "UNSUBSCRIBE_SECRET": secret},
        )
        url = Senders(cfg)._unsubscribe_url("Test+tag@example.com")
        parsed = urlsplit(url)
        self.assertEqual(parsed.scheme, "https")
        self.assertEqual(parsed.path, "/api/recruiter/unsubscribe")
        query = parse_qs(parsed.query)
        self.assertEqual(query["email"], ["Test+tag@example.com"])
        self.assertTrue(verify_unsubscribe_token(query["email"][0], query["t"][0], secret))

    def test_unsubscribe_url_rejects_http_base(self):
        cfg = RecruiterConfig(
            root=self.root,
            data_dir=self.root,
            yaml={},
            env={"UNSUBSCRIBE_BASE_URL": "http://app.wah-lah.com", "UNSUBSCRIBE_SECRET": "x" * 40},
        )
        self.assertEqual(Senders(cfg)._unsubscribe_url("test@example.com"), "")


if __name__ == "__main__":
    unittest.main()