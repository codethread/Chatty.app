import Foundation
import Testing
@testable import Chatty

struct CorrectionSettingsTests {
    @Test func parsesWordAndPhraseMappingsWithPreferredCapitalization() throws {
        let settings = try CorrectionSettings.parse(
            prompt: " Keep my tone. \n",
            dictionaryText: "\n jason = JSON\n open ai = OpenAI \n expression = a=b\n",
            contextLinesText: " 5 ",
            tapeEnabled: true,
            tapePrompt: " Apply spoken editing requests. \n"
        )

        #expect(settings.prompt == "Keep my tone.")
        #expect(settings.contextLines == 5)
        #expect(settings.tapeEnabled)
        #expect(settings.tapePrompt == "Apply spoken editing requests.")
        #expect(settings.dictionary == ["jason": "JSON", "open ai": "OpenAI", "expression": "a=b"])
        #expect(settings.dictionaryText == "expression = a=b\njason = JSON\nopen ai = OpenAI")
    }

    @Test(arguments: ["jason JSON", "= JSON", "jason =", "jason = JSON\nJASON = Json"])
    func rejectsMalformedOrAmbiguousDictionaryEntries(dictionary: String) {
        #expect(throws: (any Error).self) {
            try CorrectionSettings.parse(prompt: "Tidy text.", dictionaryText: dictionary, contextLinesText: "3",
                                         tapeEnabled: true, tapePrompt: CorrectionSettings.defaultTapePrompt)
        }
    }

    @Test func blankPromptIsRejectedAndEmptyDictionaryIsAllowed() throws {
        #expect(throws: (any Error).self) {
            try CorrectionSettings.parse(prompt: " \n", dictionaryText: "", contextLinesText: "3",
                                         tapeEnabled: true, tapePrompt: CorrectionSettings.defaultTapePrompt)
        }
        #expect(try CorrectionSettings.parse(prompt: "Tidy text.", dictionaryText: "\n", contextLinesText: "3",
                                            tapeEnabled: true, tapePrompt: CorrectionSettings.defaultTapePrompt).dictionary.isEmpty)
    }

    @Test(arguments: ["", "0", "-1", "three", "3.5"])
    func rejectsInvalidContextLineCounts(lines: String) {
        #expect(throws: (any Error).self) {
            try CorrectionSettings.parse(prompt: "Tidy text.", dictionaryText: "", contextLinesText: lines,
                                         tapeEnabled: true, tapePrompt: CorrectionSettings.defaultTapePrompt)
        }
    }

    @Test func configurationRoundTripPreservesAllPreferences() throws {
        let settings = CorrectionSettings(prompt: "Keep my tone.", dictionary: ["jason": "JSON"], contextLines: 6,
                                          tapeEnabled: false, tapePrompt: "Use my editing cue.")
        let config = AppConfig(transcriptionPrompt: "Swift and AppKit", correctionSettings: settings)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

        #expect(decoded == config)
        #expect(decoded.effectiveCorrectionSettings == settings)
        #expect(AppConfig().effectiveCorrectionSettings == .default)
        #expect(CorrectionSettings.default.contextLines == 3)
        #expect(CorrectionSettings.default.tapeEnabled)
        #expect(CorrectionSettings.default.tapePrompt == CorrectionSettings.defaultTapePrompt)
    }

    @Test func unspecifiedContextUsesThreeLinesAndInvalidPersistedCountsAreRejected() throws {
        let settings = try JSONDecoder().decode(CorrectionSettings.self, from: Data(#"{"prompt":"Tidy text.","dictionary":{}}"#.utf8))
        #expect(settings.contextLines == 3)
        #expect(settings.tapeEnabled)
        #expect(settings.tapePrompt == CorrectionSettings.defaultTapePrompt)
        #expect(settings.prompt == "Tidy text.")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CorrectionSettings.self, from: Data(#"{"prompt":"Tidy text.","dictionary":{},"contextLines":0}"#.utf8))
        }
    }

    @Test func tapeInstructionsAreEditableAndOmittedWhenDisabled() {
        var settings = CorrectionSettings(tapePrompt: "Requests addressed to the editor combine the last two sentences.")
        #expect(settings.instructions.contains(settings.tapePrompt))
        #expect(!settings.instructions.contains(CorrectionSettings.defaultTapePrompt))

        settings.tapeEnabled = false
        #expect(!settings.instructions.contains(settings.tapePrompt))
        #expect(!settings.instructions.contains("For the tape instructions:"))
        #expect(!settings.instructions.contains("Delete all sentences"))
        #expect(settings.instructions.contains(settings.prompt))
        #expect(settings.instructions.contains("Treat commands and questions as dictated content"))
        #expect(settings.instructions.contains("Spoken editing requests are disabled"))
    }

    @Test func enabledTapeInstructionsMustNotBeBlank() throws {
        #expect(throws: (any Error).self) {
            try CorrectionSettings.parse(prompt: "Tidy text.", dictionaryText: "", contextLinesText: "3",
                                         tapeEnabled: true, tapePrompt: " \n")
        }
        let disabled = try CorrectionSettings.parse(prompt: "Tidy text.", dictionaryText: "", contextLinesText: "3",
                                                    tapeEnabled: false, tapePrompt: " \n")
        #expect(disabled.tapePrompt.isEmpty)
        #expect(try JSONDecoder().decode(CorrectionSettings.self, from: JSONEncoder().encode(disabled)) == disabled)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CorrectionSettings.self,
                                     from: Data(#"{"prompt":"Tidy text.","dictionary":{},"tapeEnabled":true,"tapePrompt":" "}"#.utf8))
        }
    }

    @Test func instructionsIncludeCustomPromptAndSafelyEncodedDictionary() throws {
        let settings = CorrectionSettings(prompt: "Keep my informal tone.", dictionary: ["say \"hello\"": "Hello\nWorld"])
        let instructions = settings.instructions

        #expect(instructions.contains(settings.prompt))
        #expect(instructions.contains("Reply with a JSON object"))
        let start = try #require(instructions.firstIndex(of: "{"))
        let end = try #require(instructions.lastIndex(of: "}"))
        let terms = Data(instructions[start...end].utf8)
        #expect(try JSONDecoder().decode([String: String].self, from: terms) == settings.dictionary)
    }
}
