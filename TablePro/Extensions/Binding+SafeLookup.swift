//
//  Binding+SafeLookup.swift
//  TablePro
//

import SwiftUI

extension Binding where Value: MutableCollection & RandomAccessCollection,
    Value.Element: Identifiable {
    func element(_ item: Value.Element) -> Binding<Value.Element> {
        Binding<Value.Element>(
            get: {
                wrappedValue.first(where: { $0.id == item.id }) ?? item
            },
            set: { newValue in
                guard let index = wrappedValue.firstIndex(where: { $0.id == newValue.id }) else {
                    return
                }
                wrappedValue[index] = newValue
            }
        )
    }
}
