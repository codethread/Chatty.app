import Foundation
import Testing
@testable import Chatty

struct CorrectionSettingsTests {
    @Test func parsesWordAndPhraseMappingsWithPreferredCapitalization() throws {
        let settings = try CorrectionSettings.parse(
            prompt: " Keep my tone. \n",
            dictionaryText: "\n jason = JSON\n open ai = OpenAI \n expression = a=b\n"
        )

        #expect(settings.prompt == "Keep my tone.")
        #expect(settings.dictionary == ["jason": "JSON", "open ai": "OpenAI", "expression": "a=b"])
        #expect(settings.dictionaryText == "expression = a=b\njason = JSON\nopen ai = OpenAI")
    }

    @Test(arguments: ["jason JSON", "= JSON", "jason =", "jason = JSON\nJASON = Json"])
    func rejectsMalformedOrAmbiguousDictionaryEntries(dictionary: String) {
        #expect(throws: (any Error).self) {
            try CorrectionSettings.parse(prompt: "Tidy text.", dictionaryText: dictionary)
        }
    }

    @Test func blankPromptIsRejectedAndEmptyDictionaryIsAllowed() throws {
        #expect(throws: (any Error).self) {
            try CorrectionSettings.parse(prompt: " \n", dictionaryText: "")
        }
        #expect(try CorrectionSettings.parse(prompt: "Tidy text.", dictionaryText: "\n").dictionary.isEmpty)
    }

    @Test func configurationRoundTripPreservesAllPreferences() throws {
        let settings = CorrectionSettings(prompt: "Keep my tone.", dictionary: ["jason": "JSON"])
        let config = AppConfig(transcriptionPrompt: "Swift and AppKit", correctionSettings: settings)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

        #expect(decoded == config)
        #expect(decoded.effectiveCorrectionSettings == settings)
        #expect(AppConfig().effectiveCorrectionSettings == .default)
    }

    @Test func instructionsIncludeCustomPromptAndSafelyEncodedDictionary() throws {
        let settings = CorrectionSettings(prompt: "Keep my informal tone.", dictionary: ["say \"hello\"": "Hello\nWorld"])
        let instructions = settings.instructions

        #expect(instructions.contains(settings.prompt))
        #expect(instructions.contains("Reply only with the edited sentence."))
        let start = try #require(instructions.firstIndex(of: "{"))
        let end = try #require(instructions.lastIndex(of: "}"))
        let terms = Data(instructions[start...end].utf8)
        #expect(try JSONDecoder().decode([String: String].self, from: terms) == settings.dictionary)
    }
}
