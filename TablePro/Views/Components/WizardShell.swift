//
//  WizardShell.swift
//  TablePro
//

import SwiftUI

/// The frame every modal wizard in the app shares: a title with a step line, the
/// current step's content, and a footer carrying the error text and the navigation
/// buttons.
///
/// Extracted from the data transfer wizard so a second wizard is a set of steps
/// rather than a second copy of this layout. What belongs to a feature stays with
/// the feature: the step descriptions, the buttons and what they do, and any
/// confirmation the feature needs are all passed in.
struct WizardShell<Content: View, Footer: View>: View {
    static var defaultSize: CGSize { CGSize(width: 760, height: 560) }

    let title: String
    let stepDescription: String
    var errorMessage: String?
    var size: CGSize = WizardShell.defaultSize
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footerBar
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(stepDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footerBar: some View {
        HStack {
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()

            footer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// The running-step view both wizards use: what is happening, how many rows have
/// gone through, a bar where the total is known and a spinner where it is not, and
/// one line about what stopping does.
struct WizardProgressView: View {
    let statusLine: String
    let isStatusSecondary: Bool
    let rowCount: Int
    let progressFraction: Double?
    let footnote: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 8) {
                HStack {
                    Text(statusLine)
                        .font(.body)
                        .foregroundStyle(isStatusSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text("\(rowCount.formatted()) rows")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: 520)

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
