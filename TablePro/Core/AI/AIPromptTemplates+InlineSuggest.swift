//
//  AIPromptTemplates+InlineSuggest.swift
//  TablePro
//
//  Prompt template for inline SQL suggestions (ghost text completions).
//

import Foundation

extension AIPromptTemplates {
    /// System prompt for inline SQL suggestions
    /// - Parameter schemaContext: Optional schema context (e.g. table/column names) to append to the prompt
    /// - Returns: The system prompt string for the AI provider
    static func inlineSuggestSystemPrompt(schemaContext: String? = nil) -> String {
        var prompt = """
        You are an SQL autocomplete engine. Given the SQL text before the cursor, \
        return ONLY the completion text that should appear after the cursor. \
        Rules: \
        - Return raw SQL only, no markdown, no backticks, no explanation. \
        - Do NOT repeat any text that already exists before the cursor. \
        - Keep completions concise (1-2 lines preferred). \
        - If no meaningful completion exists, return an empty string. \
        - Match the SQL dialect and style of the existing query. \
        - The completion must continue EXACTLY from the cursor position — \
        if the cursor is mid-word (e.g., "SE[CURSOR]"), \
        complete the word without adding spaces (e.g., "LECT * FROM ..."). \
        - Only include a leading space when the cursor is after a complete token followed by no space.
        """

        if let schema = schemaContext, !schema.isEmpty {
            prompt += "\n\n" + schema
        }

        return prompt
    }

    /// Build a prompt for inline SQL suggestion
    /// - Parameters:
    ///   - textBefore: The text before the cursor (capped at 2000 chars)
    ///   - fullQuery: The full query text for additional context
    /// - Returns: The user message for the AI provider
    static func inlineSuggest(textBefore: String, fullQuery: String) -> String {
        let nsTextBefore = textBefore as NSString
        let maxBefore = 2_000
        let cappedBefore: String
        if nsTextBefore.length > maxBefore {
            cappedBefore = nsTextBefore.substring(from: nsTextBefore.length - maxBefore)
        } else {
            cappedBefore = textBefore
        }

        return "Complete the SQL after [CURSOR]:\n\n\(cappedBefore)[CURSOR]"
    }
}
