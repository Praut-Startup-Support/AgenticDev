import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class SiteContent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.site = (ROOT / "site/index.html").read_text()

    def test_install_command_has_visible_accessible_copy_button(self):
        self.assertIn('class="copy-command"', self.site)
        self.assertIn('aria-label="Kopírovat instalační příkaz / Copy install command"', self.site)
        self.assertIn("navigator.clipboard && window.isSecureContext", self.site)
        self.assertIn("document.execCommand('copy')", self.site)

    def test_site_describes_current_operational_features(self):
        for fact in ("signed task", "GitHub identities", "read-only analysis",
                     "Claude or ChatGPT subscription", "update --check"):
            self.assertIn(fact, self.site)
        self.assertNotIn("formspree.io", self.site)
        self.assertNotIn("agenticdev subscribe", self.site)


if __name__ == "__main__":
    unittest.main()
