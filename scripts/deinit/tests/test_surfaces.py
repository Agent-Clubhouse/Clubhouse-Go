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

    def test_deferred_teardown_body_and_retained_owners_are_visible(self):
        source = 'class Owner { nonisolated deinit { Task { @MainActor [presenter] in withExtendedLifetime(presenter) {} } } }'
        a, b = self.surfaces(source, source.replace('[presenter]', ''))
        self.assertNotEqual(a['deinits'], b['deinits'])
        self.assertEqual(a['classes'], b['classes'])
        self.assertNotEqual(a['deinits'], self.surfaces(source.replace('@MainActor', ''))[0]['deinits'])

    def test_lifecycle_transition_captures_and_producers_require_review(self):
        source = 'func make() { let service = PlainService(); _ = CompanionLifecycle { active in await service.transition(active) } }'
        a, b = self.surfaces(source, source.replace('PlainService()', 'UIOwner()'))
        self.assertEqual(a['captureSites']['constructor:CompanionLifecycle'][0]['producers'], {'service': 'PlainService ( )'})
        self.assertNotEqual(a['captureSites'], b['captureSites'])

    def test_conditional_and_duplicate_deinits_cannot_hide_behind_the_last_body(self):
        body = 'nonisolated deinit { Task { @MainActor [presenter] in withExtendedLifetime(presenter) {} } }'
        approved = self.surfaces('class Owner { ' + body + ' }')[0]['deinits']['Owner']
        for declarations in [
            '#if DEBUG\n nonisolated deinit {}\n #else\n ' + body + '\n #endif',
            '#if DEBUG\n ' + body + '\n #endif',
            'nonisolated deinit {}\n ' + body,
        ]:
            with self.subTest(declarations=declarations):
                actual = self.surfaces('class Owner {\n' + declarations + '\n}')[0]['deinits']['Owner']
                self.assertNotEqual(approved, actual)

    def test_explicit_and_self_initializers_preserve_lifecycle_capture_review(self):
        for call, enclosure in [
            ('CompanionLifecycle.init', 'func make() { %s }'),
            ('Self.init', 'class CompanionLifecycle { static func make() { %s } }'),
            ('Self.init', 'extension CompanionLifecycle { static func make() { %s } }'),
        ]:
            with self.subTest(call=call, enclosure=enclosure):
                source = enclosure % ('let service = PlainService(); _ = ' + call + ' { active in await service.transition(active) }')
                a, b = self.surfaces(source, source.replace('PlainService()', 'UIOwner()'))
                self.assertEqual(a['captureSites']['constructor:CompanionLifecycle'][0]['producers'], {'service': 'PlainService ( )'})
                self.assertNotEqual(a['captureSites'], b['captureSites'])

    def test_explicit_lifecycle_initializer_cannot_hide_new_ui_capture(self):
        source = 'func make(_ view: UIView) { _ = CompanionLifecycle.init { _ in use(view) } }'
        surface = self.surfaces(source)[0]
        self.assertIn('constructor:CompanionLifecycle', surface['captureSites'])
        site = surface['captureSites']['constructor:CompanionLifecycle'][0]
        self.assertEqual(site['producers'], {'view': 'UIView'})

    def test_conditional_deinit_fingerprints_every_body(self):
        source = '''class Owner {
        #if DEBUG
        nonisolated deinit {}
        #else
        nonisolated deinit { Task { @MainActor [presenter] in withExtendedLifetime(presenter) {} } }
        #endif
        }'''
        changed = source.replace('nonisolated deinit {}', 'nonisolated deinit { releaseUI() }')
        a, b = self.surfaces(source, changed)
        self.assertNotEqual(a['deinits'], b['deinits'])

    def test_contextually_typed_initializer_cannot_hide_new_ui_capture(self):
        source = '''
        @MainActor func make(_ view: UIView) {
            let lifecycle: CompanionLifecycle = .init { _ in _ = view.alpha }
            withExtendedLifetime(lifecycle) {}
        }
        '''
        surface = self.surfaces(source)[0]
        self.assertIn('constructor:CompanionLifecycle', surface['captureSites'])
        site = surface['captureSites']['constructor:CompanionLifecycle'][0]
        self.assertEqual(site['producers'], {'view': 'UIView'})

    def test_contextual_owner_initializers_in_properties_returns_and_parameters(self):
        for source in [
            'class Owner { let view: UIView; lazy var lifecycle: CompanionLifecycle = .init { _ in _ = self.view.alpha } }',
            'func make(_ view: UIView) -> CompanionLifecycle { return .init { _ in _ = view.alpha } }',
            'func make(_ view: UIView) -> CompanionLifecycle { .init { _ in _ = view.alpha } }',
            'func consume(_ lifecycle: CompanionLifecycle) {}\nfunc make(_ view: UIView) { consume(.init { _ in _ = view.alpha }) }',
            'class Owner { func consume(_ lifecycle: CompanionLifecycle) {} ; func make(_ view: UIView) { self.consume(.init { _ in _ = view.alpha }) } }',
            'func consume(_ value: Int) {}\nclass Owner { func consume(_ lifecycle: CompanionLifecycle) {}; func make(_ view: UIView) { consume(.init { _ in _ = view.alpha }) } }',
            'func consume(_ value: Int) {}\nfunc make(_ consume: (CompanionLifecycle) -> Void, _ view: UIView) { consume(.init { _ in _ = view.alpha }) }',
            'func consume(_ value: Int) {}\nclass Owner { init(_ consume: (CompanionLifecycle) -> Void, _ view: UIView) { consume(.init { _ in _ = view.alpha }) } }',
            'func consume(_ value: Int) {}\nfunc make(_ view: UIView) { func consume(_ lifecycle: CompanionLifecycle) {}; consume(.init { _ in _ = view.alpha }) }',
            'class Owner { var lifecycle: CompanionLifecycle; func make(_ view: UIView) { self.lifecycle = .init { _ in _ = view.alpha } } }',
            'typealias Owner = CompanionLifecycle\nfunc make(_ view: UIView) { let lifecycle: Owner = .init { _ in _ = view.alpha } }',
            'class CompanionLifecycle { static func make(_ view: UIView) -> Self { .init { _ in _ = view.alpha } } }',
            'extension CompanionLifecycle { static func make(_ view: UIView) -> Self { .init { _ in _ = view.alpha } } }',
        ]:
            with self.subTest(source=source):
                surface = self.surfaces(source)[0]
                self.assertIn('constructor:CompanionLifecycle', surface['captureSites'])
                self.assertNotIn('unresolved:contextual-init', surface['captureSites'])
                self.assertNotEqual(surface['captureSites'], self.surfaces(source.replace('view.alpha', 'view.isHidden'))[0]['captureSites'])

    def test_unresolved_contextual_owner_initializers_fail_closed(self):
        for expression in ['consume(.init { _ in _ = view.alpha })',
                           'consume(.init(transition: handler))',
                           'consume(.init(service: service))',
                           'consume(.init(factory))']:
            with self.subTest(expression=expression):
                source = 'func make(_ view: UIView, handler: Handler, service: Service, factory: Factory) { ' + expression + ' }'
                surface = self.surfaces(source)[0]
                self.assertIn('unresolved:contextual-init', surface['captureSites'])

    def test_unrelated_contextual_value_initializers_do_not_require_capture_review(self):
        for source in [
            'func make() { let point: CGPoint = .init(x: 1, y: 2) }',
            'func make() { consume(.init(x: 1, y: 2)) }',
            'struct Actions { init(open: () -> Void) {} }\nfunc make(_ view: UIView) { let actions: Actions = .init(open: { _ = view.alpha }) }',
            'class Owner { var cache: [String: Bytes]; func make(_ data: Data) { cache["key"] = .init(data) } }',
            'struct Attachment { var bytes: Bytes }\nfunc make(_ data: Data) -> Attachment { return .init(bytes: .init(data)) }',
            'typealias Point = CGPoint\nfunc make() { _ = Point(x: 1, y: 2); _ = Point.init(x: 1, y: 2) }',
            'func make() { _ = CoreGraphics.CGPoint(x: 1, y: 2) }',
        ]:
            with self.subTest(source=source):
                self.assertEqual(self.surfaces(source)[0]['captureSites'], {})

    def test_ambiguous_and_generic_contexts_do_not_claim_a_non_owner_type(self):
        for source in [
            'func consume(_ value: Int) {}\nfunc consume(_ value: CompanionLifecycle) {}\nfunc make(_ view: UIView) { consume(.init { _ in _ = view.alpha }) }',
            'func consume(_ value: Int) {}\nfunc make(_ view: UIView) { let consume = getSink(); consume(.init { _ in _ = view.alpha }) }',
            'func make<T>(_ view: UIView) -> T { return .init { _ in _ = view.alpha } }',
            'class Owner {\n#if DEBUG\nvar lifecycle: CompanionLifecycle\n#else\nvar lifecycle: Other\n#endif\nfunc make(_ view: UIView) { self.lifecycle = .init { _ in _ = view.alpha } }\n}',
        ]:
            with self.subTest(source=source):
                self.assertIn('unresolved:contextual-init', self.surfaces(source)[0]['captureSites'])

    def test_unresolved_owner_shapes_include_required_and_defaulted_parameters(self):
        declarations = '''
        class CompanionLifecycle { init(transition: Handler) {} }
        class CompanionDecisionQueue { init(delay: Delay = .zero, commit: Handler) {} }
        class CompanionStateLifetime { init(_ factory: Factory) {} }
        class CompanionStore { init(service: Service, clock: Clock = .live) {} }
        '''
        for expression, owner in [
            ('.init(commit: handler)', True),
            ('.init(delay: .zero, commit: handler)', True),
            ('.init(service: service)', True),
            ('.init(factory)', True),
            ('.init()', False),
            ('.init(delay: .zero)', False),
            ('.init(x: 1, y: 2)', False),
        ]:
            with self.subTest(expression=expression):
                source = declarations + '\nfunc make() { consume(' + expression + ') }'
                self.assertEqual('unresolved:contextual-init' in self.surfaces(source)[0]['captureSites'], owner)

    def test_generic_associated_types_cannot_claim_a_resolved_non_owner(self):
        declarations = 'protocol Container { associatedtype Owner }\n'
        for body in [
            'func make<T: Container>(_ type: T.Type, _ view: UIView) -> T.Owner where T.Owner == CompanionLifecycle { .init { _ in _ = view.alpha } }',
            'func make<T: Container>(_ type: T.Type, _ view: UIView) where T.Owner == CompanionLifecycle { let make = { () -> T.Owner in .init { _ in _ = view.alpha } }; _ = make }',
            'func consume<T: Container>(_ type: T.Type, _ owner: T.Owner) {}\nfunc make<T: Container>(_ type: T.Type, _ view: UIView) where T.Owner == CompanionLifecycle { consume(type, .init { _ in _ = view.alpha }) }',
            'extension Container where Owner == CompanionLifecycle { func make(_ view: UIView) -> Owner { .init { _ in _ = view.alpha } } }',
            'extension Container where Owner == CompanionLifecycle { func make(_ view: UIView) -> Self.Owner { .init { _ in _ = view.alpha } } }',
            'typealias Selected<T: Container> = T.Owner\nfunc make<T: Container>(_ type: T.Type, _ view: UIView) where T.Owner == CompanionLifecycle { _ = Selected<T> { _ in _ = view.alpha } }',
        ]:
            with self.subTest(body=body):
                sites = self.surfaces(declarations + body)[0]['captureSites']
                self.assertTrue({'constructor:CompanionLifecycle', 'unresolved:contextual-init'} & sites.keys())

    def test_alias_and_qualified_owner_constructors_cannot_hide_captures(self):
        for source in [
            'typealias Owner = CompanionLifecycle\nfunc make(_ view: UIView) { _ = Owner { _ in _ = view.alpha } }',
            'typealias Owner = CompanionLifecycle\nfunc make(_ view: UIView) { _ = Owner.init { _ in _ = view.alpha } }',
            'typealias First = ClubhouseGo.CompanionLifecycle\ntypealias Owner = First\nfunc make(_ view: UIView) { _ = Owner.init { _ in _ = view.alpha } }',
            'typealias Owner = CompanionLifecycle\nextension Owner { static func make(_ view: UIView) -> Self { Self.init { _ in _ = view.alpha } } }',
            'func make(_ view: UIView) { _ = ClubhouseGo.CompanionLifecycle { _ in _ = view.alpha } }',
            'func make(_ view: UIView) { _ = ClubhouseGo.CompanionLifecycle.init { _ in _ = view.alpha } }',
        ]:
            with self.subTest(source=source):
                sites = self.surfaces(source)[0]['captureSites']
                self.assertTrue({'constructor:CompanionLifecycle', 'unresolved:contextual-init'} & sites.keys())
