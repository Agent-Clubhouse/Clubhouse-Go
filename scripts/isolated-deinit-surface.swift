// Parsed ownership review inputs; no source-file hashes and no application execution.
// SwiftParser/SwiftSyntax ship in the selected Xcode toolchain; no package download.
import Foundation
import SwiftParser
import SwiftSyntax

func canonical(_ node: some SyntaxProtocol) -> String {
    node.tokens(viewMode: .sourceAccurate).map(\.text).joined(separator: " ")
}
func stored(_ binding: PatternBindingSyntax) -> Bool {
    guard let block = binding.accessorBlock else { return true }
    if case .accessors(let accessors) = block.accessors {
        return accessors.allSatisfy { ["willSet", "didSet"].contains($0.accessorSpecifier.text) }
    }
    return false
}
func fieldType(_ binding: PatternBindingSyntax) -> String {
    if let type = binding.typeAnnotation?.type { return canonical(type) }
    guard let expression = binding.initializer?.value else { return "<requires explicit type>" }
    if expression.is(BooleanLiteralExprSyntax.self) { return "Bool" }
    if expression.is(StringLiteralExprSyntax.self) { return "String" }
    if expression.is(IntegerLiteralExprSyntax.self) { return "Int" }
    if expression.is(FloatLiteralExprSyntax.self) { return "Double" }
    if let call = expression.as(FunctionCallExprSyntax.self) {
        // Only constructor-shaped inference: do not fingerprint arbitrary method bodies.
        let callee = canonical(call.calledExpression)
        if callee.first?.isUppercase == true { return callee }
    }
    return "<requires explicit type>"
}
func mergeProperty(_ name: String, _ type: String, into result: inout [String: String]) {
    result[name] = Array(Set((result[name]?.components(separatedBy: " || ") ?? []) + [type])).sorted().joined(separator: " || ")
}
func properties(_ members: MemberBlockItemListSyntax) -> [String: String] {
    var result: [String: String] = [:]
    for member in members {
        if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
            for clause in conditional.clauses {
                if let declarations = clause.elements?.as(MemberBlockItemListSyntax.self) {
                    for (name, type) in properties(declarations) { mergeProperty(name, type, into: &result) }
                }
            }
        }
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              !variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) else { continue }
        let ownership = variable.modifiers.filter { ["weak", "unowned", "lazy"].contains($0.name.text) }.map { canonical($0) }
        let wrappers = variable.attributes.compactMap { $0.as(AttributeSyntax.self) }.filter {
            !["ObservationIgnored", "available", "objc", "nonobjc"].contains($0.attributeName.trimmedDescription)
        }.map { canonical($0) }
        for binding in variable.bindings where stored(binding) {
            let name = canonical(binding.pattern)
            mergeProperty(name, (ownership + wrappers + [fieldType(binding)]).joined(separator: " "), into: &result)
        }
    }
    return result
}
final class References: SyntaxVisitor {
    var names = Set<String>()
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.baseName.text); return .visitChildren
    }
}
// Capture-site producer bindings only, not the surrounding method. This notices a
// reviewed `service`/`store` being supplied by a different owner under the same name.
func dependencies(_ node: some SyntaxProtocol) -> [String: String] {
    let refs = References(viewMode: .sourceAccurate); refs.walk(node)
    var result: [String: String] = [:]
    var ancestor = Syntax(node).parent
    while let current = ancestor {
        if let items = current.as(CodeBlockItemListSyntax.self) {
            for item in items.reversed() where item.positionAfterSkippingLeadingTrivia.utf8Offset < node.positionAfterSkippingLeadingTrivia.utf8Offset {
                guard let declaration = item.item.as(VariableDeclSyntax.self) else { continue }
                for binding in declaration.bindings {
                    let name = canonical(binding.pattern)
                    if refs.names.contains(name), result[name] == nil {
                        result[name] = binding.typeAnnotation.map { canonical($0.type) }
                            ?? binding.initializer.map { canonical($0.value) } ?? "<requires explicit type>"
                    }
                }
            }
        }
        let parameters: FunctionParameterListSyntax?
        if let function = current.as(FunctionDeclSyntax.self) { parameters = function.signature.parameterClause.parameters }
        else if let initializer = current.as(InitializerDeclSyntax.self) { parameters = initializer.signature.parameterClause.parameters }
        else { parameters = nil }
        for parameter in parameters ?? FunctionParameterListSyntax([]) {
            let name = parameter.secondName?.text ?? parameter.firstName.text
            if refs.names.contains(name), result[name] == nil { result[name] = canonical(parameter.type) }
        }
        if let cls = current.as(ClassDeclSyntax.self), refs.names.contains("self") { result["self"] = cls.name.text }
        ancestor = current.parent
    }
    return result
}
func captureSite(_ node: some SyntaxProtocol) -> [String: Any] {
    ["expression": canonical(node), "producers": dependencies(node)]
}
func argumentTypes(_ parameters: FunctionParameterListSyntax, for call: FunctionCallExprSyntax) -> [TypeSyntax]? {
    let parameters = Array(parameters)
    var next = 0
    var types: [TypeSyntax] = []
    for argument in call.arguments {
        while next < parameters.count,
              parameters[next].firstName.text != (argument.label?.text ?? "_"),
              parameters[next].defaultValue != nil { next += 1 }
        guard next < parameters.count,
              parameters[next].firstName.text == (argument.label?.text ?? "_") else { return nil }
        types.append(parameters[next].type)
        next += 1
    }
    if call.trailingClosure != nil {
        guard next < parameters.count,
              parameters[next..<parameters.count - 1].allSatisfy({ $0.defaultValue != nil }),
              call.additionalTrailingClosures.isEmpty else { return nil }
        next = parameters.count
    }
    guard parameters[next...].allSatisfy({ $0.defaultValue != nil }) else { return nil }
    return types
}
final class DeclarationIndex: SyntaxVisitor {
    var path: [String] = []
    var initializers: [String: [FunctionParameterListSyntax]] = [:]
    var functions: [String: [FunctionParameterListSyntax]] = [:]
    var fields: [String: [String: [TypeSyntax]]] = [:]
    var aliases: [String: [TypeSyntax]] = [:]
    var genericNames = Set<String>()
    var associatedNames = Set<String>()

    func enter(_ name: String, _ members: MemberBlockItemListSyntax) {
        path.append(name)
        recordFields(members, on: path.joined(separator: "."))
    }
    func recordFields(_ members: MemberBlockItemListSyntax, on owner: String) {
        for member in members {
            if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
                for clause in conditional.clauses {
                    if let members = clause.elements?.as(MemberBlockItemListSyntax.self) { recordFields(members, on: owner) }
                }
            }
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) else { continue }
            for binding in variable.bindings where stored(binding) {
                if let type = binding.typeAnnotation?.type {
                    fields[owner, default: [:]][canonical(binding.pattern), default: []].append(type)
                }
            }
        }
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node.memberBlock.members); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { path.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node.memberBlock.members); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { path.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node.memberBlock.members); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { path.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node.memberBlock.members); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { path.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.extendedType.trimmedDescription, node.memberBlock.members); return .visitChildren }
    override func visitPost(_ node: ExtensionDeclSyntax) { path.removeLast() }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        initializers[path.joined(separator: "."), default: []].append(node.signature.parameterClause.parameters)
        return .visitChildren
    }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        var ancestor = Syntax(node).parent
        while let current = ancestor {
            if current.is(CodeBlockSyntax.self) { return .visitChildren }
            ancestor = current.parent
        }
        functions[(path + [node.name.text]).joined(separator: "."), default: []].append(node.signature.parameterClause.parameters)
        return .visitChildren
    }
    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        aliases[node.name.text, default: []].append(node.initializer.value)
        return .visitChildren
    }
    override func visit(_ node: GenericParameterSyntax) -> SyntaxVisitorContinueKind {
        genericNames.insert(node.name.text)
        return .visitChildren
    }
    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        associatedNames.insert(node.name.text)
        return .visitChildren
    }
    func field(_ name: String, on owner: String) -> TypeSyntax? {
        guard let types = fields[owner]?[name], Set(types.map { canonical($0) }).count == 1 else { return nil }
        return types[0]
    }
    func enclosingName(near node: some SyntaxProtocol, seen: Set<String> = []) -> String? {
        var ancestor = Syntax(node).parent
        while let current = ancestor {
            if let node = current.as(ClassDeclSyntax.self) { return node.name.text }
            if let node = current.as(StructDeclSyntax.self) { return node.name.text }
            if let node = current.as(ActorDeclSyntax.self) { return node.name.text }
            if let node = current.as(EnumDeclSyntax.self) { return node.name.text }
            if let node = current.as(ExtensionDeclSyntax.self) { return name(node.extendedType, seen: seen) }
            ancestor = current.parent
        }
        return nil
    }
    func resolvedName(_ name: String, seen: Set<String> = []) -> String? {
        guard !genericNames.contains(name), !associatedNames.contains(name) else { return nil }
        guard let alternatives = aliases[name] else { return name }
        guard !seen.contains(name) else { return nil }
        let names = alternatives.compactMap { self.name($0, seen: seen.union([name])) }
        return names.count == alternatives.count && Set(names).count == 1 ? names[0] : nil
    }
    func name(_ type: TypeSyntax, seen: Set<String> = []) -> String? {
        if let optional = type.as(OptionalTypeSyntax.self) { return name(optional.wrappedType, seen: seen) }
        if let attributed = type.as(AttributedTypeSyntax.self) { return name(attributed.baseType, seen: seen) }
        if let member = type.as(MemberTypeSyntax.self), name(member.baseType, seen: seen) == nil { return nil }
        guard let name = type.as(IdentifierTypeSyntax.self)?.name.text ?? type.as(MemberTypeSyntax.self)?.name.text else { return nil }
        if name == "Self" { return enclosingName(near: type, seen: seen) }
        return resolvedName(name, seen: seen)
    }
    func constructorName(_ expression: ExprSyntax) -> String? {
        if let generic = expression.as(GenericSpecializationExprSyntax.self) { return constructorName(generic.expression) }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            if ["Self", "self"].contains(reference.baseName.text) { return enclosingName(near: expression) }
            return resolvedName(reference.baseName.text)
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
           let owner = constructorName(base) {
            return member.declName.baseName.text == "init" ? owner : resolvedName(member.declName.baseName.text)
        }
        return nil
    }
}
final class Surface: SyntaxVisitor {
    let declarations: DeclarationIndex
    var path: [String] = []
    var classes: [String: [String: Any]] = [:]
    var deinits: [String: [String]] = [:]
    var values: [String: [String: String]] = [:]
    var sites: [String: [[String: Any]]] = [:]
    let constructors = Set(["CompanionStateLifetime", "CompanionDecisionQueue", "CompanionStore", "CompanionLifecycle"])
    let callbacks = Set(["onUnreachable", "onRoutes", "prepareResume"])
    init(declarations: DeclarationIndex) {
        self.declarations = declarations
        super.init(viewMode: .sourceAccurate)
    }
    func visibleBinding(_ name: String, near node: some SyntaxProtocol) -> (found: Bool, type: TypeSyntax?) {
        var ancestor = Syntax(node).parent
        while let current = ancestor {
            if let items = current.as(CodeBlockItemListSyntax.self) {
                for item in items.reversed() where item.positionAfterSkippingLeadingTrivia.utf8Offset < node.positionAfterSkippingLeadingTrivia.utf8Offset {
                    guard let variable = item.item.as(VariableDeclSyntax.self) else { continue }
                    for binding in variable.bindings where canonical(binding.pattern) == name { return (true, binding.typeAnnotation?.type) }
                }
            }
            let parameters = current.as(FunctionDeclSyntax.self)?.signature.parameterClause.parameters
                ?? current.as(InitializerDeclSyntax.self)?.signature.parameterClause.parameters
            for parameter in parameters ?? FunctionParameterListSyntax([]) where (parameter.secondName?.text ?? parameter.firstName.text) == name { return (true, parameter.type) }
            if current.is(ClosureExprSyntax.self) { return (true, nil) }
            if let block = current.as(MemberBlockSyntax.self) {
                let owner = block.parent?.as(ExtensionDeclSyntax.self)?.extendedType.trimmedDescription ?? path.joined(separator: ".")
                return (declarations.fields[owner]?[name] != nil, declarations.field(name, on: owner))
            }
            ancestor = current.parent
        }
        let type = declarations.field(name, on: path.joined(separator: "."))
        return (declarations.fields[path.joined(separator: ".")]?[name] != nil, type)
    }
    func visibleFunctions(_ name: String, near node: some SyntaxProtocol) -> [FunctionParameterListSyntax] {
        var ancestor = Syntax(node).parent
        while let current = ancestor {
            if let items = current.as(CodeBlockItemListSyntax.self) {
                let functions = items.compactMap { $0.item.as(FunctionDeclSyntax.self) }.filter { $0.name.text == name }
                if !functions.isEmpty { return functions.map { $0.signature.parameterClause.parameters } }
            }
            if let block = current.as(MemberBlockSyntax.self) {
                let owner = block.parent?.as(ExtensionDeclSyntax.self)?.extendedType.trimmedDescription ?? path.joined(separator: ".")
                return declarations.functions[owner + "." + name] ?? []
            }
            ancestor = current.parent
        }
        return declarations.functions[(path + [name]).joined(separator: ".")] ?? declarations.functions[name] ?? []
    }
    func returnType(near node: some SyntaxProtocol) -> TypeSyntax? {
        var ancestor = Syntax(node).parent
        while let current = ancestor {
            if let closure = current.as(ClosureExprSyntax.self) { return closure.signature?.returnClause?.type }
            if let function = current.as(FunctionDeclSyntax.self) { return function.signature.returnClause?.type }
            if let binding = current.as(PatternBindingSyntax.self) { return binding.typeAnnotation?.type }
            if current.is(InitializerDeclSyntax.self) { return nil }
            ancestor = current.parent
        }
        return nil
    }
    func contextualType(_ expression: Syntax) -> TypeSyntax? {
        guard var parent = expression.parent else { return nil }
        if parent.is(ExprListSyntax.self), let sequence = parent.parent { parent = sequence }
        if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) { return contextualType(parent) }
        if let initializer = parent.as(InitializerClauseSyntax.self) {
            return initializer.parent?.as(PatternBindingSyntax.self)?.typeAnnotation?.type
                ?? initializer.parent?.as(FunctionParameterSyntax.self)?.type
        }
        if parent.is(ReturnStmtSyntax.self) { return returnType(near: parent) }
        if let item = parent.as(CodeBlockItemSyntax.self),
           item.parent?.as(CodeBlockItemListSyntax.self)?.count == 1 { return returnType(near: item) }
        if let argument = parent.as(LabeledExprSyntax.self),
           let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
           let offset = call.arguments.enumerated().first(where: { $0.element.id == argument.id })?.offset {
            var signatures: [FunctionParameterListSyntax] = []
            if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let binding = visibleBinding(reference.baseName.text, near: call)
                if binding.found {
                    var type = binding.type
                    while let attributed = type?.as(AttributedTypeSyntax.self) { type = attributed.baseType }
                    guard let function = type?.as(FunctionTypeSyntax.self),
                          function.parameters.count == call.arguments.count,
                          call.arguments.allSatisfy({ $0.label == nil }) else { return nil }
                    return Array(function.parameters)[offset].type
                }
                signatures = visibleFunctions(reference.baseName.text, near: call)
            } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                      let base = member.base?.as(DeclReferenceExprSyntax.self) {
                let binding = visibleBinding(base.baseName.text, near: call)
                let owner: String
                if base.baseName.text == "self" { owner = path.joined(separator: ".") }
                else if binding.found {
                    guard let type = binding.type, let name = declarations.name(type) else { return nil }
                    owner = name
                } else { owner = base.baseName.text }
                signatures = declarations.functions[owner + "." + member.declName.baseName.text] ?? []
            }
            var constructor = call.calledExpression.trimmedDescription
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init" {
                constructor = member.base?.trimmedDescription ?? contextualType(Syntax(call)).flatMap { declarations.name($0) } ?? ""
            }
            if let initializers = declarations.initializers[constructor] { signatures += initializers }
            guard signatures.count <= 1 else { return nil }
            let types = signatures.compactMap { argumentTypes($0, for: call)?[offset] }
            if !types.isEmpty {
                return Set(types.map { canonical($0) }).count == 1 ? types[0] : nil
            }
            if signatures.isEmpty, let label = argument.label?.text {
                return declarations.field(label, on: constructor)
            }
        }
        if let sequence = parent.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
                  elements[2].id == expression.id else { return nil }
            if let reference = elements[0].as(DeclReferenceExprSyntax.self) {
                return visibleBinding(reference.baseName.text, near: sequence).type
            }
            if let member = elements[0].as(MemberAccessExprSyntax.self), member.base?.trimmedDescription == "self" {
                return declarations.field(member.declName.baseName.text, on: path.joined(separator: "."))
            }
            if let subscriptCall = elements[0].as(SubscriptCallExprSyntax.self),
               let reference = subscriptCall.calledExpression.as(DeclReferenceExprSyntax.self),
               let type = visibleBinding(reference.baseName.text, near: sequence).type {
                return type.as(DictionaryTypeSyntax.self)?.value ?? type.as(ArrayTypeSyntax.self)?.element
            }
        }
        return nil
    }
    func possibleOwner(_ call: FunctionCallExprSyntax) -> Bool {
        if call.trailingClosure != nil { return true }
        let signatures = constructors.flatMap { declarations.initializers[$0] ?? [] }
        if !signatures.isEmpty {
            if signatures.contains(where: { $0.contains { $0.ellipsis != nil } || argumentTypes($0, for: call) != nil }) { return true }
            if constructors.allSatisfy({ declarations.initializers[$0] != nil }) { return false }
        }
        return call.arguments.contains {
            guard let label = $0.label?.text else { return true }
            return ["service", "transition", "commit"].contains(label)
        }
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        path.append(node.name.text)
        let macros = node.attributes.compactMap { $0.as(AttributeSyntax.self) }.filter {
            !["MainActor", "available", "objc", "nonobjc"].contains($0.attributeName.trimmedDescription)
        }.map { canonical($0) }
        classes[path.joined(separator: ".")] = [
            "properties": properties(node.memberBlock.members),
            "bases": node.inheritanceClause?.inheritedTypes.map { canonical($0.type) } ?? [],
            "storageMacros": macros
        ]
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { path.removeLast() }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        var ancestor = Syntax(node).parent
        var conditional = false
        while let current = ancestor {
            if current.is(IfConfigDeclSyntax.self) { conditional = true; break }
            ancestor = current.parent
        }
        deinits[path.joined(separator: "."), default: []].append((conditional ? "<conditional> " : "") + canonical(node))
        return .visitChildren
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        path.append(node.name.text)
        var ancestor = Syntax(node).parent
        var isLocal = false
        while let current = ancestor {
            if current.is(CodeBlockSyntax.self) || current.is(ClosureExprSyntax.self) { isLocal = true; break }
            ancestor = current.parent
        }
        if !isLocal { values[path.joined(separator: ".")] = properties(node.memberBlock.members) }
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { path.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        path.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { path.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        path.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { path.removeLast() }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let expression = node.calledExpression
        if let member = expression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init" {
            if member.base == nil {
                if let type = contextualType(Syntax(node)), let name = declarations.name(type) {
                    if constructors.contains(name) { sites["constructor:" + name, default: []].append(captureSite(node)) }
                } else if possibleOwner(node) {
                    sites["unresolved:contextual-init", default: []].append(captureSite(node))
                }
                return .visitChildren
            }
        }
        if let callee = declarations.constructorName(expression) {
            if constructors.contains(callee) { sites["constructor:" + callee, default: []].append(captureSite(node)) }
        } else if possibleOwner(node) {
            let candidate = expression.as(GenericSpecializationExprSyntax.self)?.expression ?? expression
            let identifier = candidate.as(DeclReferenceExprSyntax.self)?.baseName.text
                ?? candidate.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            if let identifier, identifier == "init" || identifier.first?.isUppercase == true || declarations.aliases[identifier] != nil {
                sites["unresolved:contextual-init", default: []].append(captureSite(node))
            }
        }
        return .visitChildren
    }
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        if elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
           let member = elements[0].as(MemberAccessExprSyntax.self), callbacks.contains(member.declName.baseName.text) {
            sites["callback:" + member.declName.baseName.text, default: []].append(captureSite(node))
        }
        return .visitChildren
    }
}
func canonicalJSON(_ value: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}
var output: [String: Any] = [:]
var trees: [String: SourceFileSyntax] = [:]
let declarations = DeclarationIndex(viewMode: .sourceAccurate)
for file in CommandLine.arguments.dropFirst() {
    let tree = Parser.parse(source: try String(contentsOfFile: file, encoding: .utf8))
    guard !tree.hasError else { fatalError("Cannot parse ownership review input: \(file)") }
    trees[file] = tree
    declarations.walk(tree)
}
for file in trees.keys.sorted() {
    let visitor = Surface(declarations: declarations); visitor.walk(trees[file]!)
    for name in visitor.classes.keys {
        visitor.classes[name]!["nestedValueProperties"] = visitor.values.filter { $0.key.hasPrefix(name + ".") }
    }
    output[file] = ["classes": visitor.classes, "deinits": visitor.deinits.mapValues { $0.sorted() }, "captureSites": visitor.sites.mapValues { $0.sorted { canonicalJSON($0) < canonicalJSON($1) } }]
}
let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(json)
