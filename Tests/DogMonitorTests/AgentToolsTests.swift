import XCTest
@testable import DogMonitor

/// One registry, four wire formats: every tool survives JSON in each, and Gemini gets only the schema keys it accepts.
final class AgentToolsTests: XCTestCase {
    private func roundTrip(_ x: Any) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: x))
    }

    private func keys(_ x: Any) -> Set<String> {
        if let d = x as? [String: Any] { return d.reduce(into: Set(d.keys)) { $0.formUnion(keys($1.value)) } }
        if let a = x as? [Any] { return a.reduce(into: Set()) { $0.formUnion(keys($1)) } }
        return []
    }

    func testEveryToolEncodesForEveryProvider() throws {
        let all = AgentTools.all
        let claude = try XCTUnwrap(roundTrip(AgentTools.claude(all)) as? [[String: Any]])
        let openAI = try XCTUnwrap(roundTrip(AgentTools.openAI(all)) as? [[String: Any]])
        let mcp = try XCTUnwrap(roundTrip(AgentTools.mcp(all)) as? [[String: Any]])
        let gemini = try XCTUnwrap(roundTrip(AgentTools.gemini(all)) as? [[String: Any]])
        let decls = try XCTUnwrap(gemini.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(gemini.count, 1)
        for (i, t) in all.enumerated() {
            let schema = try XCTUnwrap(roundTrip(t.schema) as? NSDictionary)
            XCTAssertEqual(claude[i]["name"] as? String, t.name)
            XCTAssertEqual(claude[i]["description"] as? String, t.summary)
            XCTAssertEqual(claude[i]["input_schema"] as? NSDictionary, schema, t.name)
            XCTAssertEqual(openAI[i]["type"] as? String, "function")
            XCTAssertEqual(openAI[i]["name"] as? String, t.name)
            XCTAssertEqual(openAI[i]["strict"] as? Bool, false)
            XCTAssertEqual(openAI[i]["parameters"] as? NSDictionary, schema, t.name)
            XCTAssertEqual(mcp[i]["name"] as? String, t.name)
            XCTAssertEqual(mcp[i]["inputSchema"] as? NSDictionary, schema, t.name)
            XCTAssertEqual(decls[i]["name"] as? String, t.name)
            XCTAssertEqual(decls[i]["description"] as? String, t.summary)
            let empty = (t.schema["properties"] as? [String: Any])?.isEmpty ?? true
            if empty {
                XCTAssertNil(decls[i]["parameters"], "\(t.name): Gemini rejects an object with no properties")
            } else {
                XCTAssertEqual(decls[i]["parameters"] as? NSDictionary, schema, "\(t.name): nothing to strip in the registry")
            }
        }
        XCTAssertFalse(keys(gemini).contains("additionalProperties"))
        XCTAssertFalse(keys(gemini).contains("$schema"))
    }

    func testGeminiStripsUnsupportedKeysButKeepsFieldsWithThoseNames() throws {
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "additionalProperties": false,
            "properties": [
                "default": ["type": "string", "default": "x", "description": "a field named default"],
                "list": ["type": "array", "items": ["type": "object", "additionalProperties": false,
                                                    "properties": ["n": ["type": "integer", "enum": [1, 2]]]]],
            ],
            "required": ["default"],
        ]
        let tool = AgentTool(name: "t", summary: "s", schema: schema, kind: .web)
        let decl = try XCTUnwrap((AgentTools.gemini([tool]).first?["functionDeclarations"] as? [[String: Any]])?.first)
        let p = try XCTUnwrap(roundTrip(try XCTUnwrap(decl["parameters"])) as? NSDictionary)
        let expected: [String: Any] = [
            "type": "object",
            "properties": [
                "default": ["type": "string", "description": "a field named default"],
                "list": ["type": "array", "items": ["type": "object", "properties": ["n": ["type": "integer", "enum": [1, 2]]]]],
            ],
            "required": ["default"],
        ]
        XCTAssertEqual(p, try XCTUnwrap(roundTrip(expected) as? NSDictionary))
    }
}
