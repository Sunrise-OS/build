import unittest

from pathlib import Path
import tempfile

from crosspkg.model import BuildContext, Recipe
from unittest.mock import patch

from crosspkg.runner import PackageError, dependency_order, load_recipes, plan, validate_recipe


def recipe(name, dependencies=()):
    return Recipe(name, "1", name, "local", "test", build_dependencies=dependencies)


class RunnerTests(unittest.TestCase):
    def test_builtin_recipes_load(self):
        recipes = load_recipes()
        self.assertEqual(set(recipes), {"availability-pl", "bringup-pid1", "llvm", "rust", "mold-macho", "bootstrap-python"})

    def test_dependency_order(self):
        recipes = {"app": recipe("app", ("lib",)), "lib": recipe("lib")}
        self.assertEqual(dependency_order(["app"], recipes), ["lib", "app"])

    def test_unknown_dependency(self):
        with self.assertRaisesRegex(PackageError, "unknown package"):
            dependency_order(["app"], {"app": recipe("app", ("missing",))})

    def test_cycle(self):
        recipes = {"a": recipe("a", ("b",)), "b": recipe("b", ("a",))}
        with self.assertRaisesRegex(PackageError, "dependency cycle"):
            dependency_order(["a"], recipes)

    def test_rejects_unsupported_target(self):
        recipes = load_recipes()
        with self.assertRaisesRegex(PackageError, "does not support target"):
            plan(["bringup-pid1"], recipes, "x86_64-linux-gnu")

    def test_environment_excludes_ambient_path(self):
        context = BuildContext(Path('/root'), Path('/work'), Path('/out'), 'build', 'host', 'target',
                               dependency_outputs={'llvm': Path('/packages/llvm')})
        self.assertEqual(context.environment()['PATH'], '/packages/llvm/bin')
        self.assertNotIn('LD_PRELOAD', context.environment())

    def test_tool_must_come_from_package(self):
        with tempfile.TemporaryDirectory() as directory:
            context = BuildContext(Path(directory), Path(directory), Path(directory), 'b', 'h', 't',
                                   dependency_outputs={'llvm': Path(directory)})
            with self.assertRaisesRegex(RuntimeError, 'does not provide'):
                context.tool('llvm', 'clang')

    def test_source_revision_is_enforced(self):
        package = Recipe("test", "1", "test", "source", "expected", source_checkout=__file__)
        with patch("crosspkg.runner.subprocess.run") as run:
            run.return_value.stdout = "different\n"
            with self.assertRaisesRegex(PackageError, "source revision mismatch"):
                validate_recipe(package)


if __name__ == "__main__":
    unittest.main()
