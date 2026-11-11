"""Tests for framework/native/ci/check-no-swift: no Swift in an app but what its Info.plist declares.

Each case is a small git repository, an xcodebuild log and an app bundle whose executable clang links here,
with or without the system's Swift library. The log lines are Xcode 27.2's, from a build of examples/simple
with a Swift bridge (2026-11-10).
"""
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "native" / "ci" / "check-no-swift"


def swift_log(*files):
    lines = ["SwiftDriver App normal arm64 com.apple.xcode.tools.swift.compiler (in target 'App' from project 'App')"]
    for f in files:
        escaped = f.replace(" ", "\\ ")
        name = Path(f).name.replace(" ", "\\ ")
        lines.append(f"SwiftCompile normal arm64 Compiling\\ {name} {escaped} (in target 'App' from project 'App')")
        lines.append(f"SwiftCompile normal arm64 {escaped} (in target 'App' from project 'App')")
    lines.append("SwiftCompile normal arm64 (in target 'App' from project 'App')")
    return "\n".join(["CompileC build/App.o /src/LNApp.m normal arm64 objective-c"] + lines) + "\n"


class CheckNoSwift(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = Path(tempfile.mkdtemp())
        (cls.tools / "probe.c").write_text("int main(void) { return 0; }\n")
        sdk = subprocess.run(["xcrun", "--show-sdk-path"], check=True, capture_output=True, text=True).stdout.strip()
        clang = ["xcrun", "clang", "-arch", "arm64", str(cls.tools / "probe.c"), "-o"]
        subprocess.run(clang + [str(cls.tools / "plain")], check=True)
        subprocess.run(clang + [str(cls.tools / "swift"), f"-L{sdk}/usr/lib/swift", "-lswiftCore"], check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tools)

    def setUp(self):
        self.repo = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.repo)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / "ios").mkdir()

    def track(self, path, text="let x = 1\n"):
        f = self.repo / path
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
        subprocess.run(["git", "-C", str(self.repo), "add", path], check=True)

    def app(self, swift=False, declared=None, catalyst=False, bundled=()):
        app = self.repo / "out" / "App.app"
        contents = app / "Contents" if catalyst else app
        binary = contents / "MacOS" / "App" if catalyst else app / "App"
        binary.parent.mkdir(parents=True)
        shutil.copy(self.tools / ("swift" if swift else "plain"), binary)
        info = {"CFBundleExecutable": "App"}
        if declared is not None:
            info["LNSwiftSources"] = declared
        with open(contents / "Info.plist", "wb") as f:
            plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
        for name in bundled:
            (contents / "Frameworks").mkdir(exist_ok=True)
            (contents / "Frameworks" / name).write_bytes(b"")
        return app

    def run_check(self, log, app):
        (self.repo / "build.log").write_text(log)
        r = subprocess.run([str(SCRIPT), "build.log", str(app)], cwd=self.repo, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def test_no_swift(self):
        code, out = self.run_check("CompileC a.o a.m\n", self.app())
        self.assertEqual((code, out.strip()), (0, "no Swift: 0 sources, 0 compile steps, no Swift library linked or bundled"))

    def test_undeclared_source_in_the_tree(self):
        self.track("ios/Bridge.swift")
        code, out = self.run_check("", self.app())
        self.assertEqual(code, 1)
        self.assertIn("ios/Bridge.swift", out)

    def test_undeclared_compile_steps(self):
        code, out = self.run_check(swift_log("/src/ios/Bridge.swift"), self.app())
        self.assertEqual(code, 1)
        self.assertIn("4 Swift compile steps", out)

    def test_undeclared_linked_library(self):
        code, out = self.run_check("", self.app(swift=True))
        self.assertEqual(code, 1)
        self.assertIn("the app links Swift libraries:\n/usr/lib/swift/libswiftCore.dylib", out)

    def test_an_empty_declaration_declares_nothing(self):
        code, out = self.run_check("", self.app(swift=True, declared=[]))
        self.assertEqual(code, 1)
        self.assertIn("the app links Swift libraries:", out)

    def test_declared_bridge(self):
        self.track("ios/Bridge.swift")
        log = swift_log(str(self.repo / "ios" / "Bridge.swift"))
        code, out = self.run_check(log, self.app(swift=True, declared=["Bridge.swift"]))
        self.assertEqual((code, out.strip()), (0, "no Swift but the app's own: 1 declared (Bridge.swift), 4 compile steps, "
                                                  "the system's Swift libraries linked, none bundled"))

    def test_declared_in_a_directory_with_a_space(self):
        self.track("my app/ios/Bridges/LLM.swift")
        log = swift_log(str(self.repo / "my app" / "ios" / "Bridges" / "LLM.swift"))
        code, out = self.run_check(log, self.app(swift=True, declared=["Bridges/LLM.swift"]))
        self.assertEqual(code, 0, out)

    def test_declared_and_another_source_in_the_tree(self):
        self.track("ios/Bridge.swift")
        self.track("ios/Other.swift")
        self.track("ios/NotBridge.swift")
        code, out = self.run_check(swift_log(str(self.repo / "ios" / "Bridge.swift")),
                                   self.app(swift=True, declared=["Bridge.swift"]))
        self.assertEqual(code, 1)
        self.assertIn("ios/Other.swift", out)
        # a declared name is a whole path component, never the end of another file's name
        self.assertIn("ios/NotBridge.swift", out)
        self.assertNotIn("\nios/Bridge.swift", out)

    def test_declared_and_another_source_compiled(self):
        self.track("ios/Bridge.swift")
        log = swift_log(str(self.repo / "ios" / "Bridge.swift"), "/deps/Package/Sources/Thing.swift")
        code, out = self.run_check(log, self.app(swift=True, declared=["Bridge.swift"]))
        self.assertEqual(code, 1)
        self.assertIn("Swift compiled that the app does not declare (swiftSources):\n/deps/Package/Sources/Thing.swift", out)

    def test_declared_and_a_bundled_library(self):
        self.track("ios/Bridge.swift")
        code, out = self.run_check(swift_log(str(self.repo / "ios" / "Bridge.swift")),
                                   self.app(swift=True, declared=["Bridge.swift"], bundled=["libswiftCore.dylib"]))
        self.assertEqual(code, 1)
        self.assertIn("the app bundles Swift libraries", out)

    def test_mac_catalyst_bundle(self):
        self.track("ios/Bridge.swift")
        log = swift_log(str(self.repo / "ios" / "Bridge.swift"))
        code, out = self.run_check(log, self.app(swift=True, declared=["Bridge.swift"], catalyst=True))
        self.assertEqual(code, 0, out)
        code, out = self.run_check("", self.app_again(catalyst=True))
        self.assertEqual(code, 1)
        self.assertIn("ios/Bridge.swift", out)

    def app_again(self, **kw):
        shutil.rmtree(self.repo / "out")
        return self.app(**kw)


if __name__ == "__main__":
    unittest.main()
