//
//  DuplicateSqlPreviewPane.swift
//  TablePro
//

import SwiftUI

/// The script the run executes, rebuilt from the same plan every time an option changes. The
/// statements that only exist once the new table does are labelled rather than guessed, so the
/// preview never shows SQL the run will not send.
struct DuplicateSqlPreviewPane: View {
    let model: DuplicateTableSheetModel

    var body: some View {
        VStack(spacing: 0) {
            DDLTextView(
                ddl: model.previewScript,
                fontSize: .constant(13),
                databaseType: model.databaseType
            )
            Divider()
            HStack {
                Text("Statements built when this runs are labelled in the script.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Copy")) {
                    ClipboardService.shared.writeText(model.previewScript)
                }
                .disabled(model.previewScript.isEmpty)
            }
            .padding(8)
        }
    }
}
