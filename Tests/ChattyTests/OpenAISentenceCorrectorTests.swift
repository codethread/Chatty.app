import Foundation
import Testing
@testable import Chatty

struct OpenAISentenceCorrectorTests {
    @Test func sendsSentenceAndSettingsWithoutReasoningOrResponseStorage() throws {
        let settings = CorrectionSettings(prompt: "Keep my tone.", dictionary: ["jason": "JSON"])
        let request = try OpenAISentenceCorrector.request("um use jason.", settings: settings, apiKey: "test-key")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(body["model"] as? String == "gpt-5.4-mini")
        #expect(body["instructions"] as? String == settings.instructions)
        #expect(body["input"] as? String == "um use jason.")
        #expect((body["reasoning"] as? [String: String])?["effort"] == "none")
        #expect(body["store"] as? Bool == false)
        #expect(body["service_tier"] as? String == "priority")
    }

    @Test func readsTextAfterReasoningAndAcrossOutputParts() throws {
        let data = Data(#"{"status":"completed","service_tier":"priority","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":" Use "},{"type":"output_text","text":"JSON.\n"}]}]}"#.utf8)
        let response = try OpenAISentenceCorrector.response(from: data, statusCode: 200)
        #expect(response.text == "Use JSON.")
        #expect(response.serviceTier == "priority")
    }

    @Test(arguments: [
        #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"Partial"}]}]}"#,
        #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"Declined"}]}]}"#,
        #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"  "}]}]}"#,
        #"{"status":"completed","output":[]}"#,
        #"{"unexpected":"schema"}"#,
        "not JSON"
    ])
    func rejectsIncompleteRefusedEmptyOrMalformedResponses(body: String) {
        #expect(throws: (any Error).self) {
            try OpenAISentenceCorrector.response(from: Data(body.utf8), statusCode: 200)
        }
    }

    @Test func reportsHTTPFailureWithoutExposingAPIKey() {
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-proj-private****key. Check your API key."}}"#.utf8)
        do {
            _ = try OpenAISentenceCorrector.response(from: body, statusCode: 401)
            Issue.record("Expected authentication error")
        } catch {
            #expect(error.localizedDescription.contains("401"))
            #expect(error.localizedDescription.contains("[redacted]"))
            #expect(!error.localizedDescription.contains("private"))
        }
    }
}
