import json
import tempfile
import unittest
from pathlib import Path

from recruit.config import RecruiterConfig, load_config
from recruit.compliance import Compliance
from recruit.loop import Recruiter
from recruit.prospects import ProspectStore, Prospect


def _cfg(tmp: Path) -> RecruiterConfig:
    import os

    os.environ["RECRUITER_DATA_DIR"] = str(tmp)
    os.environ["RECRUITER_DRY_RUN"] = "true"
    os.environ["RECRUITER_APPROVAL_GATE"] = "true"
    return load_config()


def stub_llm(model, system, user, **kwargs):
    if "QA agent" in system or "acceptable" in system:
        return json.dumps({"issues": [], "acceptable": True})
    return json.dumps({
        "subject": "A friendly invite to wah-lah.com",
        "body": "Hi Jordan,\n\nWah-Lah is a fun sweepstakes-style games platform — free to enter, "
                "no purchase necessary. This invite was drafted by an AI assistant (Ember).\n\nJoin on wah-lah.com: https://app.wah-lah.com?ref=abc123"
    })


class DraftFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = _cfg(Path(self.tmp.name))
        self.c = Compliance(self.cfg)
        self.s = ProspectStore(self.cfg, self.c)

    def tearDown(self):
        self.tmp.cleanup()

    def test_full_tick_drafts_and_dry_runs(self):
        self.s.upsert(Prospect(email="jordan@wah-lah.com", name="Jordan", consent=True, source="existing member"))
        r = Recruiter(self.cfg, llm=stub_llm)
        summary = r.run_once()
        self.assertTrue(summary["dry_run"])
        self.assertEqual(summary["drafted"], 1)
        self.assertEqual(summary["sent"], 0)
        events = [e["event"] for e in r.audit.rows()]
        self.assertIn("draft", events)
        self.assertIn("dry_run_skip", events)
        self.assertEqual(summary["allowed_by_caps"], min(r.cfg.daily_cap, r.cfg.max_per_hour))

    def test_hard_block_never_sent(self):
        def nudge_llm(model, system, user, **kwargs):
            return json.dumps({
                "subject": "You won a prize!!",
                "body": "You have won a guaranteed prize, buy credits to claim now.",
            })
        self.s.upsert(Prospect(email="z@wah-lah.com", name="Z", consent=True, source="t"))
        r = Recruiter(self.cfg, llm=nudge_llm)
        summary = r.run_once()
        self.assertEqual(summary["hard_blocked"], 1)
        self.assertEqual(summary["sent"], 0)
        events = [e["event"] for e in r.audit.rows()]
        self.assertIn("hard_block", events)


if __name__ == "__main__":
    unittest.main()