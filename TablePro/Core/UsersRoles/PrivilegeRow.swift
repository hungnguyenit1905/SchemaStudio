import Foundation
import TableProPluginKit

struct PrivilegeRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case category(PrivilegeCategory)
        case privilege(PluginPrivilegeDescriptor)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .category(let category): "category:\(category.key)"
        case .privilege(let descriptor): "privilege:\(descriptor.name)"
        }
    }

    var title: String {
        switch kind {
        case .category(let category): category.title
        case .privilege(let descriptor): descriptor.label
        }
    }

    var descriptor: PluginPrivilegeDescriptor? {
        guard case .privilege(let descriptor) = kind else { return nil }
        return descriptor
    }

    var category: PrivilegeCategory? {
        guard case .category(let category) = kind else { return nil }
        return category
    }
}

struct PrivilegeSection: Identifiable {
    let category: PrivilegeCategory
    let headerRow: PrivilegeRow
    let rows: [PrivilegeRow]

    var id: String { category.key }

    init(category: PrivilegeCategory, descriptors: [PluginPrivilegeDescriptor]) {
        self.category = category
        headerRow = PrivilegeRow(kind: .category(category))
        rows = descriptors.map { PrivilegeRow(kind: .privilege($0)) }
    }
}
