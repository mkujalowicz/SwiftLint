//
//  StringLiteralRule.swift
//  SwiftLint
//
//  Created by Maciej Kujalowicz on 20/04/2016.
//  Copyright © 2016 Maciej Kujalowicz. All rights reserved.
//

import Foundation
import SourceKittenFramework

extension Structure {
    internal func structureDictionariesAtOffset(byteOffset: Int) -> [[String: SourceKitRepresentable]] {
        var results = [[String: SourceKitRepresentable]]()
        
        func parse(dictionary: [String : SourceKitRepresentable]) {
            guard let
                offset = (dictionary["key.offset"] as? Int64).map({ Int($0) }),
                byteRange = (dictionary["key.length"] as? Int64).map({ Int($0) })
                    .map({NSRange(location: offset, length: $0)})
                where NSLocationInRange(byteOffset, byteRange) else {
                    return
            }
            if dictionary.kind != nil {
                results.append(dictionary)
            }
            if let subStructure = dictionary["key.substructure"] as? [SourceKitRepresentable] {
                for case let dictionary as [String : SourceKitRepresentable] in subStructure {
                    parse(dictionary)
                }
            }
        }
        parse(dictionary)
        return results
    }
}

public struct StringLiteralRule: ConfigurationProviderRule, OptInRule {
    
    public var configuration = SeverityConfiguration(.Warning)
    
    public init() {}

    public static let description = RuleDescription(
        identifier: "string_literal",
        name: "String Literals",
        description: "Should avoid using string literals.",
        nonTriggeringExamples: [
            "enum SwiftEnum: String { case SomeType = \"String\"}",
            "let some = \"String\"",
            "let a = [\"String1\", \"String2\"]",
            "let some = [\"String\": 2]",
            "class A { static let a = \"String\" }",
            "class A { class let a = \"String\" }",
            "/* \"String\" */",
            "// \"String\"",
            "print(\"String\")",
            "var some = \"\"",
            "var some = \"223\"",
            "var some = \" \"",
            "var some = \"- 23 - 23\"",
            "showMessage(NSLocalizedString(\"STRING_ID\", comment: \"\"), completion: nil)",
            "NSBundle.mainBundle().localizedStringForKey(\"STRING_ID\", value: nil, table: nil)",
            "XCTAssert(NSObject.className(), \"NSObject\")"
        ],
        triggeringExamples: [
            "var some = \"String\"",
            "class A { static var a = \"String\" }",
            "class A { class var a = \"String\" }",
            "someFun(\"String\")",
            "someFun(2, \"String\", 3, 4)",
            "func someFunc() { let a = \"String\"}",
            "func someFunc() { let a = [\"String1\", 2]}",
            "func someFunc() { let a = [\"String1\": 2]}",
            "let some = obj.pathForResource(\"String\", ofType: 2)"
        ]
    )
    
    public func validateFile(file: File) -> [StyleViolation] {
        let strings = file.syntaxMap.tokens.filter { token in
            guard token.type == SyntaxKind.String.rawValue && token.length > 2 else {
                return false
            }
            let string = file.contents.substring(token.offset, length: token.length)
            if string.rangeOfString("[^\\d\\W]", options: .RegularExpressionSearch) == nil {
                return false
            }
            if isStringTokenAtOffsetValid(token.offset, file: file) {
                return false
            } else {
                return true
            }
        }
        return strings.map {
            StyleViolation(ruleDescription: self.dynamicType.description,
                severity: configuration.severity,
                location: Location(file: file, byteOffset: $0.offset))
        }
    }
    
    private func isStringTokenAtOffsetValid(byteOffset: Int, file: File) -> Bool {
        let dictionariesStartingFromLeaf = file.structure.structureDictionariesAtOffset(byteOffset).reverse() as [[String: SourceKitRepresentable]]
        if dictionariesStartingFromLeaf.count == 0 {
            return true
        }
        // Is enum associated value ?
        if getWhitelistedStructureForDictionaries(
            dictionariesStartingFromLeaf,
            validationBlock: { $0.kind == SwiftDeclarationKind.Enumelement.rawValue ? .ValidStop: .InvalidStop }) != nil {
            return true
        }
        // Is global/class/static variable ?
        if let staticVar = getWhitelistedStructureForDictionaries(
            dictionariesStartingFromLeaf,
            validationBlock: { return StringLiteralRule.isGlobalOrStaticVarKind($0.kind, acceptCollections: true) }) {
            if StringLiteralRule.isGlobalOrStaticVarKind(staticVar.kind ?? "",
                                                         acceptCollections: false) == .InvalidStop {
                return false
            }
            if let setter = staticVar["key.setter_accessibility"] as? String where setter.isEmpty == false {
                return false // mutable variable
            } else {
                return true
            }
        }
        // Is expression call ?
        if let expressionCall = getWhitelistedStructureForDictionaries(
            dictionariesStartingFromLeaf, validationBlock: { return StringLiteralRule.isWhitelistedExpressionCallKind($0.kind, name: $0.name) }) {
            return expressionCall.kind ?? "" == "source.lang.swift.expr.call"
        }
        return false
    }
    
    private enum ValidationStatus {
        case ValidContinue
        case ValidStop
        case InvalidStop
    }
    
    private func getWhitelistedStructureForDictionaries(
        dicts: [[String: SourceKitRepresentable]],
        validationBlock: (kind: String, name: String?) -> ValidationStatus) -> [String: SourceKitRepresentable]? {
        var lastValidStruct: [String: SourceKitRepresentable]? = nil
        for dict in dicts {
            let name = dict["key.name"] as? String
            switch validationBlock(kind: dict.kind ?? "", name: name) {
            case .InvalidStop:
                return lastValidStruct
            case .ValidContinue:
                lastValidStruct = dict
            case .ValidStop:
                return dict
            }
        }
        return lastValidStruct
    }
    
    private static func isGlobalOrStaticVarKind(kind: String, acceptCollections: Bool) -> ValidationStatus {
        switch kind {
        case "source.lang.swift.expr.dictionary":
            if acceptCollections {
                return .ValidContinue
            } else {
                return .InvalidStop
            }
        case "source.lang.swift.expr.array":
            if acceptCollections {
                return .ValidContinue
            } else {
                return .InvalidStop
            }
        case SwiftDeclarationKind.VarGlobal.rawValue:
            fallthrough
        case SwiftDeclarationKind.VarClass.rawValue:
            fallthrough
        case SwiftDeclarationKind.VarStatic.rawValue:
            return .ValidContinue
        default:
            return .InvalidStop
        }
    }
    
    private static func isWhitelistedExpressionCallKind(kind: String, name: String?) -> ValidationStatus {
        switch kind {
        case SwiftDeclarationKind.VarParameter.rawValue:
            return .ValidContinue
        case "source.lang.swift.expr.call":
            guard let nameUnwrapped = name else {
                return .InvalidStop
            }
            return isExpressionWhitelisted(nameUnwrapped) ? .ValidStop: .InvalidStop
        default:
            return .InvalidStop
        }
    }
    
    private static func isExpressionWhitelisted(expr: String) -> Bool {
        return StringLiteralRule.exprWhitelistEqual.contains(expr)
            || StringLiteralRule.exprWhitelistSuffix.filter() {
                expr.hasSuffix($0)
                }.count > 0
            || StringLiteralRule.exprWhitelistPrefix.filter() {
                expr.hasPrefix($0)
                }.count > 0
    }
    
    private static let exprWhitelistEqual: [String] = [
        "print",
        "assert",
        "NSLog",
        "NSLocalizedString",
        "Selector"
    ]
    
    private static let exprWhitelistSuffix: [String] = [
        ".localizedStringForKey"
    ]
    
    private static let exprWhitelistPrefix: [String] = [
        "XCTAssert"
    ]
}
