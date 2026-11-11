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
final class Surface: SyntaxVisitor {
    var path: [String] = []
    var classes: [String: [String: Any]] = [:]
    var deinits: [String: String] = [:]
    var values: [String: [String: String]] = [:]
    var sites: [String: [[String: Any]]] = [:]
    let constructors = Set(["CompanionStateLifetime", "CompanionDecisionQueue", "CompanionStore", "CompanionLifecycle"])
    let callbacks = Set(["onUnreachable", "onRoutes", "prepareResume"])
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
        deinits[path.joined(separator: ".")] = canonical(node)
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
        let callee: String
        if let generic = node.calledExpression.as(GenericSpecializationExprSyntax.self) { callee = generic.expression.trimmedDescription }
        else { callee = node.calledExpression.trimmedDescription }
        if constructors.contains(callee) { sites["constructor:" + callee, default: []].append(captureSite(node)) }
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
for file in CommandLine.arguments.dropFirst() {
    let tree = Parser.parse(source: try String(contentsOfFile: file, encoding: .utf8))
    guard !tree.hasError else { fatalError("Cannot parse ownership review input: \(file)") }
    let visitor = Surface(viewMode: .sourceAccurate); visitor.walk(tree)
    for name in visitor.classes.keys {
        visitor.classes[name]!["nestedValueProperties"] = visitor.values.filter { $0.key.hasPrefix(name + ".") }
    }
    output[file] = ["classes": visitor.classes, "deinits": visitor.deinits, "captureSites": visitor.sites.mapValues { $0.sorted { canonicalJSON($0) < canonicalJSON($1) } }]
}
let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(json)
