import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class SiteNationBackground(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.site = (ROOT / "site/index.html").read_text()
        cls.sim = cls.site[cls.site.index("národy na pozadí"):]

    def test_uses_a_small_random_nation_count(self):
        self.assertIn("const count=3+pick(5)", self.sim)
        self.assertIn("Array.from({length:count}", self.sim)

    def test_land_only_four_neighbor_expansion_and_decline(self):
        for rule in ("if(x>0)", "if(x+1<cols)", "if(y>0)", "if(y+1<rows)"):
            self.assertIn(rule, self.sim)
        self.assertIn("const pressure=", self.sim)
        self.assertIn("cells[j]=owner", self.sim)
        self.assertIn("cells[i]=-1", self.sim)
        self.assertIn("alive<2", self.sim)

    def test_green_only_fast_local_attack_fronts(self):
        self.assertIn("const palette = [", self.sim)
        for non_green in ("240,214,74", "104,218,255", "255,112,91", "198,145,255"):
            self.assertNotIn(non_green, self.sim)
        self.assertIn("const front=[j,...neighbors(j)", self.sim)
        self.assertIn("attacks.push({from:i,to:j,owner", self.sim)
        self.assertIn("Math.floor(cells.length*.12)", self.sim)
        self.assertIn("now-last<36", self.sim)

    def test_omits_openfront_combat_and_terrain_systems(self):
        executable = self.sim[self.sim.index("(function(){"):]
        for omitted in ("allianceBehavior", "Warship", "Missile", "Mountain", "waterTile"):
            self.assertNotIn(omitted, executable)

    def test_respects_reduced_motion_and_replaces_old_backgrounds(self):
        self.assertIn("if(!reduced)raf=requestAnimationFrame(loop)", self.sim)
        self.assertIn("#rd, #dots{display:none}", self.site)

    def test_cursor_weakens_and_click_reinforces_or_creates_without_blocking_ui(self):
        self.assertIn("function cursorDecay(x,y)", self.sim)
        self.assertIn("function clickUnits(x,y)", self.sim)
        self.assertIn("strength[i]-=(dx===0&&dy===0?.028:.009)", self.sim)
        self.assertIn("nations.push(nationTraits(owner))", self.sim)
        self.assertIn("strength[center]=1", self.sim)
        self.assertIn("{passive:true}", self.sim)
        self.assertNotIn("preventDefault()", self.sim)


if __name__ == "__main__":
    unittest.main()
