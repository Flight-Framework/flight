import SwiftSyntax
import SwiftSyntaxMacros

/// `@Autowired` / `@ConfigValue` scanning, so a `@Scheduler` type is an
/// ordinary component that can inject what its jobs need.
///
/// This is the **third** copy of this logic — ComponentMacro has it, and
/// ControllerMacro says in its own comments that it "mirrors ComponentMacro
/// line for line". Copying it again is the wrong long-term answer; the right
/// one is a shared macro-support target the three import. That is a change
/// to two existing macro modules and out of scope for adding a scheduler, so
/// this is deliberately the narrowest version that does the job: the two
/// attributes, no diagnostics the other two already emit at the same sites.
enum Injection {

    struct Property {
        enum Kind {
            case autowired(qualifier: String?)
            case configValue(key: String, defaultValue: String?)
        }
        let name: String
        let typeText: String
        let kind: Kind
    }

    /// Instance stored properties carrying an injection attribute.
    static func scan(_ members: MemberBlockItemListSyntax) -> [Property] {
        var found: [Property] = []
        for member in members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isTypeLevel = variable.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            if isTypeLevel { continue }
            guard let kind = injectionKind(of: variable) else { continue }
            for binding in variable.bindings {
                guard
                    let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                    let type = binding.typeAnnotation?.type.trimmedDescription
                else { continue }
                found.append(Property(name: name, typeText: type, kind: kind))
            }
        }
        return found
    }

    /// The body of the resolving initializer, matching `@Component`'s shape
    /// exactly — a scheduler author's mental model has to transfer.
    static func initializerLines(for properties: [Property]) -> [String] {
        properties.map { property in
            switch property.kind {
            case .autowired(let qualifier):
                if let qualifier {
                    return
                        "self.\(property.name) = try container.resolve(\(property.typeText).self, qualifier: \(qualifier))"
                }
                return "self.\(property.name) = try container.resolve(\(property.typeText).self)"
            case .configValue(let key, let defaultValue):
                if let defaultValue {
                    return
                        "self.\(property.name) = try container.resolve(FlightCore.Configuration.self).getIfPresent(\(key), as: \(property.typeText).self) ?? (\(defaultValue))"
                }
                return
                    "self.\(property.name) = try container.resolve(FlightCore.Configuration.self).get(\(key), as: \(property.typeText).self)"
            }
        }
    }

    private static func injectionKind(of variable: VariableDeclSyntax) -> Property.Kind? {
        for attribute in variable.attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                let name = attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            else { continue }
            switch name {
            case "Autowired":
                return .autowired(qualifier: firstArgument(of: attr))
            case "ConfigValue":
                guard let key = firstArgument(of: attr) else { return nil }
                return .configValue(key: key, defaultValue: labeledArgument(of: attr, label: "default"))
            default:
                continue
            }
        }
        return nil
    }

    private static func firstArgument(of attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first, first.label == nil
        else { return nil }
        let text = first.expression.trimmedDescription
        return text == "nil" ? nil : text
    }

    private static func labeledArgument(of attribute: AttributeSyntax, label: String) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for argument in arguments where argument.label?.text == label {
            return argument.expression.trimmedDescription
        }
        return nil
    }
}
