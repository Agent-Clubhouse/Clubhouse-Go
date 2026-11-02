import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from deinit_surface import extract


class OwnershipSurfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / "build").mkdir(exist_ok=True)

    def surfaces(self, *sources):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as directory:
            paths = []
            for index, source in enumerate(sources):
                path = pathlib.Path(directory) / f'Fixture{index}.swift'
                path.write_text(source)
                paths.append(str(path.relative_to(ROOT)))
            result = extract(ROOT, paths)
            return [result[path] for path in paths]

    def test_only_instance_storage_and_types_affect_the_class_surface(self):
        source = '''
        @Observable final class Owner: NSObject {
            var flag = false
            weak var view: UIView?
            var text: String { didSet { save(text) } }
            static let cache = UIView()
            var computed: Int { 1 }
            func unrelated() { let temporary = UIView() }
            struct Pending { let callback: @Sendable () -> Void }
        }
        '''
        changed = source.replace('save(text)', 'print("different observer behavior")').replace('let temporary = UIView()', 'print("unrelated")').replace('var computed: Int { 1 }', 'var computed: Int { 999 }')
        a, b = self.surfaces(source, changed)
        self.assertEqual(a['classes'], b['classes'])
        fields = a['classes']['Owner']['properties']
        self.assertEqual(fields, {'flag': 'Bool', 'view': 'weak UIView ?', 'text': 'String'})
        for edit in [source.replace('view: UIView?', 'view: CALayer?'), source.replace('weak var', 'var'), source.replace('var flag = false', 'var flag = false; var layer: CALayer?'), source.replace('@Sendable () -> Void', 'UIView')]:
            self.assertNotEqual(a['classes'], self.surfaces(edit)[0]['classes'])

    def test_comments_whitespace_and_unrelated_methods_do_not_change_review_inputs(self):
        source = '''
        final class Runner {
            let service: Service
            func start() {
                let owner = PlainOwner()
                service.onRoutes = { [weak self] host, routes in self?.record(owner, routes) }
                let store = CompanionStore(service: owner)
            }
            func unrelated() { print("before") }
        }
        '''
        changed = source.replace('let owner = PlainOwner()', 'let /* note */ owner  =\n PlainOwner ( )').replace('[weak self]', '[ weak /* capture */ self ]').replace('print("before")', 'let ignored = UIWindow(); print(ignored)')
        a, b = self.surfaces(source, changed)
        self.assertEqual(a, b)
        self.assertNotEqual(a['captureSites'], self.surfaces(source.replace('PlainOwner()', 'UIOwner()'))[0]['captureSites'])
        self.assertNotEqual(a['captureSites'], self.surfaces(source.replace('[weak self]', '[self]'))[0]['captureSites'])

    def test_new_constructor_and_implicit_capture_are_visible(self):
        source = 'func make() { let view = UIView(); use(view); service.onRoutes = { _, _ in print("ok") } }'
        a, b = self.surfaces(source, source.replace('print("ok")', 'use(view)'))
        self.assertNotEqual(a['captureSites'], b['captureSites'])
        a, b = self.surfaces(source, source + '\nfunc other() { _ = CompanionStateLifetime { UIView() } }')
        self.assertNotEqual(a['captureSites'], b['captureSites'])

    def test_conditional_storage_is_not_skipped(self):
        a = self.surfaces('class Owner { #if DEBUG\n var layer: CALayer?\n #else\n var value: Int\n #endif\n }')[0]
        self.assertEqual(a['classes']['Owner']['properties'], {'layer': 'CALayer ?', 'value': 'Int'})

    def test_conditional_alternatives_of_the_same_field_are_both_reviewed(self):
        source = 'class Owner { #if DEBUG\n var item: Data\n #else\n var item: String\n #endif\n }'
        a, b = self.surfaces(source, source.replace('Data', 'UIView'))
        self.assertEqual(a['classes']['Owner']['properties']['item'], 'Data || String')
        self.assertNotEqual(a['classes'], b['classes'])

    def test_method_local_value_types_are_not_owned_class_storage(self):
        source = 'class Owner { var count = 0; func unrelated() { struct Temporary { var value: Int } } }'
        a, b = self.surfaces(source, source.replace('value: Int', 'value: UIView'))
        self.assertEqual(a['classes'], b['classes'])
